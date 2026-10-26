# User Guide

zttp runs TypeScript HTTP handlers from a single Zig
binary. The language surface is intentionally restricted so the compiler can
prove handler properties before and during local development.

## Install

Install a release build:

```bash
curl -fsSL https://raw.githubusercontent.com/srdjan/zigttp/main/install.sh | sh
zttp --help
```

Build from source with Zig `0.17.0`:

```bash
git clone https://github.com/srdjan/zigttp.git
cd zigttp
zig build -Doptimize=fast
./zig-out/bin/zttp --help
```

## First Project

```bash
zttp init my-app
cd my-app
zttp dev
```

The scaffold writes `zttp.json`, `src/handler.ts`, and
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
zttp serve -e "function handler(req) { return Response.json({ ok: true }); }"
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

A handler with no `Proof<T, P>` must prove the full default profile. A handler
that calls a virtual module does not hold `pure`, so the examples that import a
module declare the properties they hold. `zttp check`, `zttp test`, and
`zttp deploy` apply the same rule.

Use `zttp:router` when you need path parameters:

```ts
import { routerMatch } from "zttp:router";

function getUser(req: Request): Response {
    return Response.json({ id: req.params.id });
}

const routes = { "GET /users/:id": getUser };

function handler(req: Request): Proof<Response, "state_isolated" | "no_secret_leakage" | "injection_safe"> {
    const found = routerMatch(routes, req);
    if (found !== undefined) {
        req.params = found.params;
        return found.handler(req);
    }
    return Response.text("Not Found", { status: 404 });
}
```

## JSON And Validation

Use normal `JSON.parse` and `Response.json` for basic JSON. Use
`zttp:validate` or `zttp:decode` when the handler needs schema-backed
validation.

```ts
import { schemaCompile, validateJson } from "zttp:validate";

schemaCompile("todo", '{"type":"object","required":["title"]}');

function handler(req: Request): Proof<Response, "state_isolated" | "no_secret_leakage" | "injection_safe"> {
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

## Buffered SSE

Use `sseEvents(body, bounds)` from `zttp:sse` to frame a buffered event stream.
Set positive `maxBodyBytes`, `maxBlockBytes`, and `maxEvents` bounds.
The success arm contains an array of `{ event, data, id }` records.
The error arm contains a `tag` and byte `offset`.
The `unterminated_event` tag means that the body ends inside an event block.
Check `ok` before reading the events.
The framer is pure and does not read from a socket.

## TypeScript Source Profile

zts supports a practical server-side TypeScript subset and rejects constructs that
weaken analysis. Commonly rejected constructs include `var`, `while`, `class`,
`try/catch`, implicit globals, and unsupported module forms.

Handler files use `.ts`. `.js`, `.jsx`, `.tsx`, and unknown file extensions
are refused with ZTS052. Inline `-e` snippets remain virtual source and do not
claim a file extension.

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
domain such as `string`, `number`, or `T[]` needs one. Arms may split one case,
for example `{ x: true, y: true }`, `{ x: true, y: false }`, and `{ x: false }`.
A record pattern matches only a record and an array pattern only an array of
its exact length, so `when { w }` does not cover a `string`. When the arms do
not cover the type, the check reports ZTS603 and names the first missing case,
for example `missing case: when { kind: "c" }`. A `default` after full coverage,
and an arm no value can reach, is the warning ZTS216. Exactly one arm's
expression is evaluated, and an arm expression may be effectful. A match that
no arm covers evaluates to `undefined`, so its type includes `undefined`.

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
- [Sound Mode](typescript.md#sound-mode)

## HTML Rendering

Use `h` and `renderToString` to build HTML without JSX.

```ts
function handler(req: Request): Response {
    const page = h("h1", {}, "Hello");
    return Response.html(renderToString(page));
}
```
## Virtual Modules

Virtual modules are native Zig APIs exposed through `import { ... } from
"zttp:*"`. The current module list and runtime requirements are in
[Virtual Modules](virtual-modules/README.md).

Common runtime flags:

| Need | Flag |
|---|---|
| SQLite queries | `--sqlite <file>` (concurrent writers wait up to 5 seconds for the lock, then return `500`) |
| Outbound HTTP | `--outbound-http` or `--outbound-host <host>` |
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
```

Ordinary fixtures use `test`, `request`, optional `io`, and `expect` rows.
Record and replay handler I/O:

```bash
zttp serve --trace traces.jsonl src/handler.ts
zttp serve --replay traces.jsonl src/handler.ts
```

Persisted counterexamples live in the witness corpus. See [Witness Corpus](proofs-and-receipts.md#witness-corpus).

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

Production artifacts use certificate schema `5`, proof system
`zttp_pcc_v3 = 3`, self-extract format `7`, attestation
`zttp-attest-v4`, and bundle format `zttp-bundle-3`. Readers require an exact
match for each identity. Schema 4 and format 6 are refused with a rebuild instruction.
Existing self-contained binaries keep their embedded runtime.
Format 7 requires bytecode and a complete policy section.
The reader refuses truncated dependency records and bytes after the declared records.
A guarded artifact must have exact residual-plan and runtime-policy coverage before startup.
Guarded generations cannot use the certificate-free live-swap path.

Two commands answer two different questions:

```bash
# Provenance: who signed a claim about this deployment.
zttp verify http://127.0.0.1:8080

# Proof: does this exact artifact satisfy the required properties.
zttp proofs bundle --binary .zttp/deploy/my-app --out bundle
zttp proofs verify bundle --require-proof
```

`zttp verify` reads a signed claim from a live endpoint. The endpoint returns
the claim, not the artifact, so that command reports provenance only. The
endpoint also supplies the public key that checks its own signature. Without
`--trust-key <fingerprint>`, the signer is not authenticated: the command exits 0,
prints `key not pinned`, and writes `"keyPinned": false` in JSON. Pass the
64-character SHA-256 key fingerprint to authenticate the signer. A claim carries
no host binding and no checked time. Proof and
policy acceptance are established against the artifact itself, which is what
`zttp proofs verify` does. Integrity and proof are printed as separate lines
because they are separate answers: matching hashes say the bundle holds the
bytes the manifest names, and nothing more.

Proof acceptance is also what unlocks the proof response cache and unbounded
runtime reuse. A dev server has no
artifact and no certificate, so it runs without them; that is deliberate, not a
gap. See [docs/verification.md](verification.md) for what each assurance grade
means and for the list of edges the consumer discloses rather than checks.

## Expert Mode

`zttp expert` is the compiler-in-the-loop coding agent. It proposes edits and
routes every one through the same compiler checks before they land. DeepSeek is
the current default. The developer-managed local MLX-LM provider is available
through explicit `--provider local` selection.

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

The parked local recordings are historical. They do not establish current
replay compatibility or current model quality.

### How a turn runs

1. You state a goal in plain English.
2. The agent gathers compiler facts through the strict `zts_expert_query`
   operation union and uses separate proof tools where a verdict is required.
3. It authors complete source for one or more files and submits one ordered
   `propose_change_set` proposal.
4. The host acquires the recovered workspace owner and its lock. Before any
   write, it normalizes the whole source overlay, proves it once, and records
   every proof input in a read set. A draft that introduces a violation is
   rejected and the agent retries.
5. On a pass you see every normalized diff plus one aggregate proof card and
   approve or reject once. `--yes` approves every verified change set;
   `--no-edit` blocks writes entirely.
6. The host rechecks the full read set and commits under that lock and its
   crash-recovery journal. The agent never writes source files itself.

The discovery views and focused compiler projections share the
`zts_expert_query` operation union. Normalization, proof, repair, and change-set
application remain distinct authorities. Tests pin the exact provider serialization.

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
zttp expert --provider deepseek                  # explicit DeepSeek
zttp expert --yes                                # apply edits without prompting
zttp expert --no-edit                            # read-only analysis, no writes
zttp expert --resume                             # continue last session
zttp expert --provider deepseek --model deepseek-v4-pro
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
changes the provider. `/model` follows the same rule and persists the choice atomically. DeepSeek defaults to `deepseek-v4-flash`. The
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

`zttp auth deepseek` stores the DeepSeek key in `~/.zttp/providers.json` with
mode `0600`. A shell-set `DEEPSEEK_API_KEY` overrides the stored value, and the
key is validated only after DeepSeek is resolved. The Claude and OpenAI
providers were removed: `zttp auth claude` and `zttp auth openai` are refused,
`zttp auth revoke claude` and `zttp auth revoke openai` delete a key stored for
them earlier, and a session stored under either provider needs
`--provider local` or `--provider deepseek` to resume. `DEEPSEEK_BASE_URL`
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
zttp serve -e "function handler(req) { return Response.text('ok'); }"
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

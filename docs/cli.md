# CLI Reference

The build produces three binaries:

- `zttp` is the developer CLI and the local runtime entry point.
- `zttp-runtime` is the internal runtime template that self-contained outputs
  wrap. `zttp` invokes it; users never type its name.
- `zts` is the pi-free engine and compiler CLI, installed for IDE and CI
  integrations that call the analyzer directly.

Every analyzer command exposed by `zts` is also reachable as `zttp <command>`
with identical surface and output. The interactive `expert` agent and the
session `ledger` commands are the exception: they live only in `zttp`, so the
agent, its provider HTTP clients, and its API-key handling are compiled exactly
once and never linked into `zts` or the deployed `zttp-runtime`. `zts expert`
and `zts ledger` print a one-line pointer to `zttp` and exit non-zero.

Run command-specific help for exact flags:

```bash
zttp --help
zttp help --all
zttp <command> --help
```

## Core Commands

The default help shows the day-to-day workflow:

```bash
zttp init <name> [--template basic|api|htmx]
zttp dev [handler.ts]
zttp test [tests.jsonl]
zttp expert
zttp deploy
```

Core commands auto-detect `zttp.json` from the current directory or a parent.

| Command | Purpose |
|---|---|
| `init` | Create a project scaffold. |
| `dev` | Run locally, watch files, and prove on save. |
| `test` | Run declarative handler tests. |
| `expert` | Start the compiler-in-the-loop coding agent. |
| `deploy` | Build, prove, attest, and emit a local binary. |

## Run Commands

`zttp serve` runs a handler without the proof-aware watch loop:

```bash
zttp serve src/handler.ts -p 3000
zttp serve -e "function handler(req) { return Response.json({ ok: true }) }"
```

Common `dev` and `serve` flags:

| Flag | Purpose |
|---|---|
| `-p`, `--port <port>` | Listen port. |
| `-h`, `--host <host>` | Listen host. |
| `-e`, `--eval <code>` | Inline handler source. |
| `-m`, `--memory <size>` | Per-runtime JS memory ceiling. Unset means unlimited. The ceiling applies to each pooled runtime, not to the process: the pool defaults to twice the CPU count, so `-m 128m` on a 14-core host authorizes roughly 3.5 GB in total. Size the value against the pool, or pin the pool with `-n`. |
| `--max-body-size <size>` | Request body limit (default 1m); oversize returns 413. |
| `-n`, `--pool <count>` | Runtime pool size. |
| `-q`, `--quiet` | Disable request access logging. |
| `--watch` | Watch handler files. |
| `--prove` | Diff contracts before hot-swap when watching. |
| `--trace <file>` | Record request/response traces. |
| `--incident-log <file>` | Append runtime soundness incidents as JSONL. Off by default. |
| `--replay <file>` | Replay recorded traces. |
| `--test <file>` | Run JSONL handler tests. |
| `--sqlite <file>` | SQLite database for `zttp:sql`. |
| `--durable <dir>` | Durable workflow oplog directory. |
| `--system <file>` | Handler bundle manifest: the `zttp:service` HTTP registry and the `zttp:workflow` in-process sub-handler registry. An optional `entry` field names the bundle's single external HTTP entry point, validated by `zttp link`. Workflow startup fails if a local handler path is unreadable. |
| `--workflow-queue` | Persist durable workflow `call`, `follow`, and `fanout` child dispatch through the workflow queue. Requires `--durable <dir>` and `--system <file>`. |
| `--actor-queue` | Enable process-local in-memory mailboxes for `zttp:queue`. |
| `--outbound-http` / `--outbound-host <host>` | Enable outbound HTTP. The host allowlist matches on host only, not port. |
| `--outbound-timeout-ms <ms>` | Outbound connect timeout (default 10000). Implies `--outbound-http`. |
| `--outbound-max-response <size>` | Outbound response body cap (default 1m). Implies `--outbound-http`. |
| `--security-log <file>` | Append security events as JSONL: policy denials, arena audit failures, persistent-string escapes. |
| `--lifecycle <mode>` | Override the contract-derived runtime lifecycle: `ephemeral`, `bounded`, `ttl`, or `reuse`. |
| `--static <dir>` | Serve static files. |
| `--no-env-check` | Skip startup env validation. |

`dev` adds `--no-prove` (watch and reload without contract gating), `--quest` /
`--no-quest` (replay or skip the first-run proof tour), and `--record-proof`,
which captures the session's requests into a replayable proof capsule at
`.zttp/capsules/default/`. `serve --watch` takes `--prove` and `--force-swap`
(apply a breaking swap anyway) instead. Both take `--studio` when the binary was
built with `-Dstudio`.

Without `--lifecycle`, the runtime derives the pool's recycling policy from the
proven contract: `reuse` when the handler is pure, deterministic, and
state-isolated; `ttl` when it is read-only and state-isolated; `bounded`
otherwise. `bounded` recycles a runtime after 64 requests, `ttl` after 30
seconds, and `ephemeral` gives each request a fresh runtime. A hot swap
re-derives the policy unless the override is set.

`--security-log` writes one JSON object per line. A capability denial from a new
gate site is `{"event":"policy_denied","ts":...,"service":...,"action":...,"resource":{"kind":...,"id":...},"reason":...}`;
the per-module kinds (`policy_denied_env`, `policy_denied_cache`,
`policy_denied_sql`, `arena_audit_failure`, `persistent_string_escape`) are
`{"kind":...,"ts":...,"module":...,"detail":...}`. A background thread drains
the event queue and flushes it at shutdown.

Observability: per-request access logging is on by default (method, path,
status, duration, request id; disable with `-q`), and pool/latency metrics are
logged. There is no scrape-able `/metrics` endpoint yet; that is planned for a
later release.

## Inspect The Project

`zttp doctor` validates the project discovered from the current directory, a
handler path, or a `zttp.json` path, and prints a checklist for the manifest,
entry, static directory, system file, test fixture, sqlite and durable
settings, and outbound HTTP configuration:

```bash
zttp doctor
zttp doctor src/handler.ts
```

`zttp version` (alias `--version`) prints the version and exits.

## Build Commands

Both commands verify the handler first: verification is mandatory, and a
handler that fails a check produces no binary. Each emits a self-contained
binary that wraps the `zttp-runtime` template, which must be installed
alongside `zttp`.

```bash
zttp build [-o <bin>] [--no-attest]
zttp compile <handler.ts> -o <bin> [--no-attest]
```

`build` takes no handler argument: it reads `zttp.json` from the current
directory or a parent and defaults the output to `.zttp/build/<project-name>`.
`compile` is the explicit-path form for scripts that name both sides. Both sign
a proof receipt by default; `--no-attest` skips signing for that build.

`zttp deploy` is the project-level verb built on the same path; see below.

## Deploy And Proof Receipts

```bash
zttp deploy
./.zttp/deploy/<project-name>
zttp verify http://127.0.0.1:8080
```

`deploy` verifies the current project, writes a local binary, appends a
`kind=deploy` row to `.zttp/proofs.jsonl`, and signs an attestation by
default. `--no-attest` disables signing for that build.

`deploy` takes no arguments: it auto-detects the handler file and the project
name in the current directory and writes `.zttp/deploy/<project-name>`. No
credentials, Docker, or network are involved. `--local` and `--target local`
are explicit aliases for the default. Hosted cloud deploy is deferred from this
beta: `--cloud` still parses and rejects with a "not in this beta" message, and
the related account verbs (`login`, `logout`, `review`, `grants`,
`revoke-grant`) are not dispatched and read as unknown commands.

Proof ledger commands:

```bash
zttp proofs
zttp proofs show HEAD
zttp proofs diff HEAD~1 HEAD
zttp proofs export --format md --ref HEAD
zttp proofs badge
zttp proofs gate --base origin/main --head HEAD
zttp proofs replay <capsule>
```

`zttp proofs replay <capsule>` replays a capsule recorded by `zttp dev
--record-proof` against the current handler: exit 0 reproduced, 1 regression. It
fails closed when the capsule's pinned handler, contract, or policy hash no
longer matches (`--allow-version-mismatch` overrides). `zttp verify <url>`
verifies a live endpoint's attestation. `zttp proofs verify <bundle-dir>`
re-hashes a local proof bundle.

The old spelling `zttp proof replay` still works as a deprecated alias for one
release and prints a migration note. It is no longer listed in `zttp help --all`.

`zttp verify --json` includes durable workflow receipt fields when a build was
attested with a workflow contract: `durableWorkflowProofLevel`,
`durableWorkflowRetrySafe`, `durableWorkflowIdempotent`, and
`durableWorkflowFaultCovered`.

Workflow queue dead-letter commands:

```bash
zttp workflow-queue list --durable <dir>
zttp workflow-queue show --durable <dir> <item-id>
zttp workflow-queue replay --durable <dir> <item-id>
zttp workflow-queue discard --durable <dir> <item-id>
```

These commands inspect the persisted queue used by `--workflow-queue`; they do
not operate on the in-memory actor queue from `zttp:queue`.

Durable-run dead-letter commands (a sibling surface: these inspect runs that
permanently failed crash recovery, not queued child dispatch):

```bash
zttp durable dead-runs list --durable <dir>
zttp durable dead-runs show --durable <dir> <id>
zttp durable dead-runs replay --durable <dir> <id>
zttp durable dead-runs discard --durable <dir> <id>
```

See [Durable Workflows](durable-workflows.md#durable-run-recovery-and-dead-letters)
for the quarantine/restart/replay/discard semantics.

Expert-session ledgers (`zttp` only; `zts ledger` prints a pointer and exits
non-zero):

```bash
zttp ledger export --session <id> --out <path>
zttp ledger replay --input <path> --onto <git-ref>
zttp ledger stats
```

`stats` aggregates every session summary for the current workspace into the
staked metrics: expert success rate, median round-trips to a first green proof,
and median proven-path ratio.

## Spec Ratchet And Witnesses

`zttp ratchet show` compiles a handler and prints its declared and proven spec
sets, plus anything declared-but-unproven, proven-beyond-declared, or
declared-but-not-monotonic. It reports and never fails:

```bash
zttp ratchet show src/handler.ts
```

A handler with no `Proof<T, P>` annotation activates every supported spec. The
proven set is also written to `contract.json` under `provenSpecs` and rides
inside the signed `Zttp-Attest` JWS, with the active set alongside it under
`declaredSpecs`, so cross-build diffs are mechanical and attestable.

`zttp ratchet check` is deprecated and kept working for one release. `zttp
check` is the gate: it compiles the same contract and exits 1 on an
undischarged proof (`ZTS500`) and on a non-monotonic declared name.

`zttp witnesses` inspects the on-disk corpus of compiler-discovered falsifying
inputs under `.zttp/witnesses/<short-hash>/`:

```bash
zttp witnesses list [<handler>]
zttp witnesses pin <handler> <key|prefix>
zttp witnesses unpin <handler> <key|prefix>
zttp witnesses prune <handler> [--older-than <seconds>]
zttp witnesses synthesize <handler> <spec>
```

Pinned witnesses are never pruned. With no handler argument, `list` summarizes
every corpus directory found. Flow-rich specs populate the corpus automatically
through the analyzer; `synthesize` seeds a structural witness for a cause-only
spec (`deterministic`, `read_only`, `retry_safe`, `idempotent`,
`state_isolated`, `fault_covered`) from the per-property suggestion in
spec discharge. See [Witness Corpus](proofs-and-receipts.md#witness-corpus).

## Analyzer Commands

These commands are listed by `zttp help --all` from the shared `zts`
command registry:

```bash
zttp check [handler.ts] [--json] [--contract] [--types]
zttp prove <old-contract.json> <new-contract.json>
zttp prove-behavior <before.ts> <after.ts> [--json] [--sql-schema path]
zttp mock <tests.jsonl> [--port <port>]
zttp link <system.json>
zttp rollout <old-system.json> <new-system.json>
zttp edit-simulate [handler.ts] [--before old.ts]
zttp review-patch <file> [--before old.ts] [--json]
zttp gen-tests [handler.ts] [-o output.jsonl]
zttp canonicalize <file> --json
zttp normalize <file> [--write] [--check] [--json] [--sql-schema <path>]
zttp features [--json]
zttp modules [--json]
zttp restrictions [--json] [--by proof|class]
zttp meta [--json]
zttp agent --stdin-json
zttp describe-rule [name|code] [--json] [--hash] [--idioms]
zttp search <keyword> [--json]
zttp spec-check [--json]
zttp spec-hash [--json]
zttp spec-render [--out path] [--check path]
zttp module-spec-render [--check] [--json]
zttp verify-paths <file>... [--json]
zttp verify-modules <file>... [--strict] [--json]
zttp verify-modules --builtins --strict --json
zttp verify-module-manifest <manifest.json> [--json]
zttp extension-status --module-manifest <path>... [--json]
```

Use JSON mode for IDEs, CI, and review-bot integrations.

`zttp agent --stdin-json` is the only version-2 surface. It reads one request
object from standard input and writes one response object to standard output,
with logs on standard error. Every other command listed here is version 1: their
bare arrays and version-1 objects are legacy or human-facing interfaces, and an
agent must not read them as advanced-profile responses. Send `meta` first - its
payload publishes the operation set, the identity hashes each response binds,
and the payload sections this compiler does not yet generate. A request naming
any other `schema_version` gets a frozen three-key negotiation response, so
version discovery is one deterministic round trip.

Exit codes for gating: `check` returns 0 (ok), 1 (errors), or 2 (warnings only, no errors). `prove` and `prove-behavior` return 0 (safe), 1 (breaking), or 2 (usage or error). `spec-check` validates the semantics registry against the IR/bytecode tables and returns 0 (conform), 1 (divergence, with a `ZTS75x` counterexample), or 2 (error); `spec-hash` prints the registry hash for CI assertions, the way `describe-rule --hash` prints the policy hash. `spec-render --check <path>` returns 0 when the committed readable spec matches the registry, or 1 when it is stale. See [Semantics Verification](internals/semantics-verification.md) for the five mechanisms, the SMT layer, the exclusion audit, and the generated artifacts these commands own.

### Canonicalize And Normalize

The canonical profile gives common operations one spelling. `zttp check` and
`zttp verify-paths` enforce these rules as ZTS6xx diagnostics. `zttp normalize
<file> --write` rewrites the rules that can be rewritten safely, and `zttp
describe-rule <code>` prints the live rule record.

`zttp describe-rule --idioms` prints the idiom table, which is a separate
surface from the diagnostic rules. An idiom names one operation, its preferred
spelling, the spellings it supersedes, and the precondition under which a
mechanical rewrite preserves meaning. A non-idiomatic spelling is never an
error and never fails a build: it is reported at `advisory` severity, rewritten
where the rewrite is provable, and otherwise left in place. Rows whose
`rewrite_rule` is null are advisory-only.

| Code | Rule | Canonical form |
|---|---|---|
| ZTS602 | Dynamic capability access | Use literal env keys, cache namespaces, SQL query names, egress URLs, route paths, and service names. |
| ZTS604 | Avoidable `let` | Use `const` unless the binding is reassigned. |
| ZTS605 | Dynamic computed property access | Use a typed field, a literal key, or narrow the object before indexing. |
| ZTS608 | Reused arrow helper | Give reusable helpers named function declarations; keep arrows for callbacks. |
| ZTS609 | Exported function-valued `const` | Export a function declaration. |
| ZTS610 | Public helper effects | Annotate the helper return type with `Effects<T, "...">`. |
| ZTS611 | Public helper proof capsule | Annotate the helper return type with `Proof<T, "...">`. |
| ZTS623 | Internal helper ceiling | Remove the `Effects<...>`: placement is decidable, and the handler budget already bounds an internal helper. |
| ZTS612 | Effectful `?:` arm | A `?:` arm must be a pure value. Bind the effectful call first, or use `match`. |
| ZTS613 | Compound assignment | Write the full assignment. |
| ZTS614 | Non-leading object spread | Put spread first or write explicit fields. |
| ZTS615 | Complex template interpolation | Bind the value first, then interpolate the binding. |
| ZTS616 | Call-site spread | Pass explicit arguments. |
| ZTS617 | Non-trailing or non-scalar parameter default | Put the defaulted parameters last and give each a compile-time scalar. |
| ZTS618 | Nested destructuring | Destructure one level at a time. |
| ZTS619 | Unused index alias in `for...of` | Iterate the array directly. |
| ZTS620 | Boolean compared to boolean literal | Use the boolean expression or negation directly. |
| ZTS621 | Chained conditional arms | Use `match` over one scrutinee, or an if/else chain. |

A pure `?:` is canonical. Only an effectful arm (ZTS612) or a conditional
nested inside another conditional (ZTS621) is diagnosed.

```bash
zttp check --json examples/handler/handler.ts
zttp normalize src/handler.ts --check
zttp normalize src/handler.ts --write
zttp describe-rule ZTS604 --json
zttp describe-rule --hash
```

`normalize --check` exits non-zero when the file is not already canonical. It
is the right CI gate when a project wants canonical form enforced before
review. A handler that queries `zttp:sql` needs `--sql-schema`, the same schema
`check` takes: its queries are type-checked against the schema, so without one
the analysis never runs and every pass refuses.

Canonical form is the rewrite fixed point in canonical layout: 2-space indent,
an 80-column soft target, double quotes, trailing commas in multi-line lists
only, records and arrays on one line when they fit, one `match` arm per line.
Comments keep their own lines and are never reflowed, and a type annotation or
declaration prints as written - the formatter lays out code, not types.

The formatter fails closed. A construct it does not cover leaves the file in
the layout its author wrote, `normalize` says so on stderr, and `--write`
declines rather than write bytes that claim a canonical form they do not have.
JSX and TSX are the current refusal.

Canonical code reduces the number of equivalent shapes the analyzer and the
expert agent must handle. A handler with no ZTS6xx errors carries the
`canonical` proof property, and `Proof<Response, "canonical">` can discharge
against it. An advisory in the same band does not deny it: an idiom row reports
a preference about a program that is already correct, and a row whose
precondition fails emits no rewrite, so there would be nothing to act on.
Advisories are counted and printed apart from warnings for the same reason -
they never change an exit code.

## Expert Mode

The current default is DeepSeek:

```bash
zttp auth deepseek
zttp expert
```

To use local LFM, start the developer-managed server and select it explicitly:

```bash
mlx_lm.server --model LiquidAI/LFM2.5-2.6B-MLX-8bit --host 127.0.0.1 --port 8080
zttp expert --provider local
```

Useful modes:

```bash
zttp expert --resume
zttp expert --yes
zttp expert --no-edit
zttp expert --provider claude --model claude-sonnet-4-6
zttp expert --print "add a GET /health route"
zttp expert --print "..." --mode json
zttp expert --mode rpc
zttp expert --handler src/handler.ts --goal no_secret_leakage
```

| Flag | Purpose |
|---|---|
| `--resume`, `--continue` | Continue the newest session for the current project. |
| `--session-id <id>` | Resume or create a session under this id. |
| `--fork <id>` | Branch a new session from an existing one. |
| `--yes` | Apply every verified edit without prompting. |
| `--no-edit` | Let the model read and analyze files but block all writes. |
| `--provider <name>` | Select `local`, `claude`, `openai`, or `deepseek` for this launch. |
| `--model <id>` | Start on a model registered for the active provider. |
| `--tools minimal\|full` | Choose the tool preset. `full` is the default; `minimal` is workspace-read-only. |
| `--no-session` | Do not persist this run to `~/.zttp/sessions`. |
| `--no-persist-tool-output` | Persist the session without tool output bodies. |
| `--no-context-files` | Skip the `AGENTS.md` / `CLAUDE.md` project-context walk. The persona and live snapshots still ship. |
| `--no-perf-receipt` | Do not sign a `kind=perf` receipt on an applied edit. On by default. |
| `--no-equivalence-receipt` | Do not sign a `kind=equivalence` receipt on an applied edit. On by default. |
| `--print <text>` | Non-interactive: send one message, print the response, and exit. |
| `--mode json` | Emit JSON-encoded turn events to stdout (pairs with `--print`). |
| `--mode rpc` | Run in RPC mode for editor integrations. |
| `--handler <file>` | Override the handler file (default: auto-detected from `zttp.json`). |
| `--goal <property>` | Restrict the session to edits that achieve a named proof property. |
| `--max-iters <n>` | Autoloop iteration budget for a `--goal` run. Defaults to 8. |

Interactive context commands:

```text
/compact [instructions]
/settings
```

`/compact` summarizes safe older context with the active model. Optional
instructions add focus but do not replace the fixed summary contract.
`/settings` shows the resolved compaction policy. Persistent overrides load in
order from `$HOME/.zttp/settings.json` and `<cwd>/.zttp/settings.json`; the
project file wins. Only `compaction.enabled`, `maxInputTokens`, `reserveTokens`,
and `keepRecentTokens` are accepted.

RPC `compact` accepts optional `{"instructions":"..."}` and returns a typed
result object with status `compacted`, `no_change`, `not_compactable`,
`unavailable`, or `failed`. Successful results include the kept entry ID,
before/after token estimates, and summary usage. Automatic compaction emits
ordered `compaction` start/end notifications.

The explicit local provider uses `LiquidAI/LFM2.5-2.6B-MLX-8bit` through
non-streaming Chat Completions at the loopback-only `ZTTP_MLX_BASE_URL`, which defaults to
`http://127.0.0.1:8080`. Zttp checks `/health` and `/v1/models` before creating
session files. It never manages the MLX-LM process or falls back to cloud.
The local adapter was tested with MLX-LM 0.31.3 and model revision
`b372ebbb518c0e81617e25d8824427dd9ee1f08c`.

`--model <id>` accepts an exact ID from the static registry, then checks it
against the resolved provider. A model ID never switches the provider. The
resolution order is explicit launch flags, stored resume or fork identity, then
the current DeepSeek default. `/model` lists only models for the active provider, marks the
current one, and persists a valid change. RPC clients get the same allowed set
through `model.list` and the same validation through `model.set`.

The local model has a 131,072-token context and an 8,192-token request output
budget. Claude defaults to `claude-sonnet-4-6`; OpenAI defaults to
`gpt-4o-mini`; DeepSeek defaults to `deepseek-v4-flash`. `--goal` is
compiler-only: it rejects `--provider` and `--model` and bypasses model
readiness.

DeepSeek uses the same non-streaming Chat Completions shape as the local
provider, over HTTPS at `DEEPSEEK_BASE_URL`, which defaults to
`https://api.deepseek.com`. The endpoint policy admits only an HTTPS root that
carries no credential of its own; plain HTTP is refused rather than upgraded.
`deepseek-v4-flash` and `deepseek-v4-pro` both declare a 1,000,000-token context
and a 384,000-token output ceiling; zttp asks for 8,192 output tokens per turn.
A DeepSeek turn sends handler source to a third party, which the destination
line under the banner states before the first turn.

Optional cloud keys are stored in `~/.zttp/providers.json` with mode `0600`.
Environment variables `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and
`DEEPSEEK_API_KEY` override stored values after their provider is selected.

## Optional Surfaces

- `zttp studio` runs the browser proof workbench when built with `-Dstudio`.
- `zttp edge --config zttp.edge.json` runs the in-process multi-handler
  edge router when built with `-Dedge`.
- `zttp demo --scripted --out proof-demo --export proof-demo/passport`
  creates an offline Proof Passport demo.

`studio` and `edge` are compiled out of the default build. Compiled out, each
prints a one-line "rebuild with -Dstudio" or "rebuild with -Dedge" message and
exits non-zero. `studio` stays listed in `zttp help --all` so its opt-in is
discoverable.

See [User Guide](user-guide.md) for the normal project flow.

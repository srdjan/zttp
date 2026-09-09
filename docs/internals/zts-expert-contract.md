# zts Structured Tool Contract

> **Version 1.** Every shape in this document is a version-1 surface. Spec
> 4.8 keeps them available as explicitly selected legacy or human-facing
> interfaces, and an agent must not read them as advanced-profile responses.
> The version-2 protocol is `zts agent --stdin-json`, documented in
> [agent-protocol-v2.md](agent-protocol-v2.md).

This page documents the stable machine-facing analyzer surfaces used by
`zttp expert`, IDE integrations, and CI. The live command list comes from
`packages/tools/src/zts_cli.zig`.

## Version Metadata

Use:

```bash
zts meta --json
zttp meta --json
```

The metadata includes compiler version, policy version/hash, rule counts, and
feature/module summaries. Clients should compare `policy_hash` when resuming
cached analysis.

`compiler_version` names the **analyzer surface**, not the `zttp` release it
shipped in, and the two move independently. The envelope is part of the
recorded model transcript and therefore of the cassette digests, so tying this
field to the release version made every release invalidate the whole recorded
corpus while changing nothing about the analyzer. It is pinned in
`expert_meta.analyzer_surface_version`, and moving it owes a full re-record. A
client that wants the shipped release reads `zttp --version`.

## Diagnostics

Machine commands emit diagnostics with this shape:

```json
{
  "code": "ZTS300",
  "severity": "error",
  "message": "all handler paths must return Response",
  "file": "src/handler.ts",
  "line": 12,
  "column": 5,
  "suggestion": "return a Response on this path"
}
```

Code ranges:

| Range | Owner |
|---|---|
| ZTS0xx | Syntax and unsupported feature detection |
| ZTS1xx | TypeScript stripping and module parsing |
| ZTS2xx | Type checking |
| ZTS3xx | Handler verification |
| ZTS4xx | Flow and data-safety checks |
| ZTS5xx | Active spec discharge |
| ZTS6xx | Canonical profile |
| ZTS7xx | Semantics registry conformance, emitted by `spec-check` rather than by handler analysis |

## Stable Commands

| Command | Purpose |
|---|---|
| `meta --json` | Compiler and policy metadata. |
| `features --json` | Supported and rejected language feature catalog. |
| `modules --json` | Virtual module exports from the built binary. |
| `restrictions --json` | Language cuts mapped to proof value. |
| `describe-rule [name|code] --json` | Rule detail and fix guidance. |
| `search <keyword> --json` | Rule search. |
| `check <handler.ts> --json` | Analyzer result, proof envelope, diagnostics, and optional contract. |
| `verify-paths <file>... --json` | Path and flow verification. |
| `verify-modules --builtins --strict --json` | Built-in module governance. |
| `verify-module-manifest <manifest.json> --json` | Extension manifest validation. |
| `extension-status --module-manifest <path>... --json` | Extension status summary. |
| `edit-simulate [handler.ts] --stdin-json` | Pre-apply edit simulation. |
| `review-patch <file> --json` | Diff-aware post-edit review. |

Commands such as `prove`, `mock`, `link`, `rollout`, and `compile` are useful
CLI tools, but their text output is not the structured v1 contract.

## Proof Envelope

`check --json` includes:

- `diagnostics`: standard diagnostics.
- `contract`: handler contract when analysis can produce one.
- `proof`: proof-card data, active specs, proof traces, and witness counts.
- `features` and `modules`: optional catalogs on commands that request them.

Clients should ignore unknown additive fields and must not depend on object key
ordering.

## Expert Event Stream

`zttp expert --print <prompt> --mode json` emits newline-delimited events:

```json
{ "v": 4, "k": "model_text", "d": "..." }
```

The event envelope uses:

| Field | Meaning |
|---|---|
| `v` | Event schema version (currently `4`). |
| `k` | Event kind. |
| `d` | Kind-specific payload (omitted on the terminal `end` event). |

Event kinds and their `d` payloads:

| Kind | `d` payload |
|---|---|
| `user_text` | bare string (the submitted prompt) |
| `model_text` | bare string (assistant prose) |
| `system_note` | bare string (e.g. a policy-drift notice or `[expert workflow]` routing hint) |
| `tool_use` | object: `{ "id", "name", "args_json" }` |
| `tool_result` | object: `{ "tool_use_id", "tool_name", "ok", "llm_text", "body", "ui_payload"? }` |
| `proof_card` | object: `{ "llm_text", "ui_payload"? }` |
| `diagnostic_box` | object: `{ "llm_text", "ui_payload"? }` |
| `verified_change_set` | object: `{ "llm_text", "ui_payload"? }` |
| `autoloop_outcome` | object: `{ "verdict", "iterations", "goals_met", "goals_unmet", ... }` |
| `session_summary` | object: `{ "turn_count", "total_roundtrips", "verified_change_set_count", "workflow_hint_count", "first_draft_veto_pass_count", "veto_retry_count", "tool_call_count", ... }` |
| `end` | none (terminal sentinel: `{ "v": 4, "k": "end" }`) |

## In-Process Expert Tools

`tools.list` exposes compiler-native Pi tools in addition to the stable analyzer
commands above. These tools are additive and run inside the same vetoed expert
loop. `tools.list` is the live inventory; the ones below are the compiler-native
core:

| Tool | Purpose |
|---|---|
| `pi_repair_plan` | Convert verifier/property failures into typed repair intents. |
| `pi_apply_repair_plan` | Dry-run one repair intent into verified proposed source; never writes. |
| `pi_goal_candidate` | Compose repair planning and supported repair dry-runs in memory; returns verified `proposed_content` and `applied:false`; never writes. |
| `pi_goal_check` | Check property goals and return executable counterexample witnesses. |

`zttp expert --mode rpc` exposes a line-delimited JSON-RPC 2.0 interface over
stdio for long-lived clients. The agent resolves provider identity from launch
flags, persisted session metadata, or the current DeepSeek default before
constructing a backend. The explicit local provider is the loopback-only MLX-LM
Chat Completions adapter for `LiquidAI/LFM2.5-2.6B-MLX-8bit`. Provider
credentials are read only after resolution. `session.info` includes the
resolved provider and model.

Edits in RPC mode are proposed only through the model-mediated `turn` method:
the model emits one ordered `propose_change_set`, the compiler proves the
aggregate overlay, and a `verified_change_set` event is returned.
`propose_change_set` is not a directly invocable entry in
`tools.list` / `tools.invoke` (those expose the read-only analyzer tools); a
client cannot apply an unverified edit out of band. Generic `tools.invoke`
exposes only tools classified as `analyze` or `read_workspace`; process,
agent-state persistence, and workspace-write effects are not invocable there.

## Compatibility

- Additive JSON fields are allowed.
- Removing or renaming documented fields requires a contract version bump.
- Unknown event kinds must be ignored by clients that do not understand them.
- In-process expert tools must round-trip through the same JSON shapes exposed
  by the CLI commands.

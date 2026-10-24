---
title: A deny list in two tools left the other workspace tools reading secrets
date: 2026-10-24
category: security-issues
module: packages/pi model-facing workspace tools and the workspace path resolver
problem_type: security_issue
component: tooling
symptoms:
  - "`zts check` on a file named `.env.prod.ts` returned the file's secret string in a ZTS200 message."
  - "`workspace_read_file` and `workspace_search_text` refused `.env`, but twelve other model-facing tools read a secret-named path without a check."
  - "Probes on `.env`, `.pem`, and `.key` files showed no leak, because the analyzer tools refuse a file that does not end in `.ts`."
root_cause: missing_validation
resolution_type: code_fix
severity: high
related_components:
  - expert_loop
  - provider_boundary
tags:
  - pi
  - expert-agent
  - secret
  - deny-list
  - env-file
  - provider-leak
  - path-resolver
  - symlink
  - fail-open
applies_when:
  - "Adding a model-facing tool that takes a workspace path"
  - "Deciding where a workspace access rule is enforced"
  - "Judging whether a probe that found no leak covers every input"
binds:
  - packages/pi/src/tools/common.zig
  - packages/pi/src/loop.zig
proves: zig build test-expert-app
---

# A deny list in two tools left the other workspace tools reading secrets

## Problem

The expert loop sends tool results to a model provider. A secret file in the workspace must never reach that text. The secret deny list (`.env`, `.env.*`, `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`) was enforced in two tools only. Twelve other tools took a model-supplied path and read the file with no check.

## Symptoms

- `zts check` on a file named `.env.prod.ts` returned the string literal of the file in its ZTS200 message, which began `type '"SECRET_MARKER_123"'`. The `zts_check` tool runs the same check in-process, so the model would receive that string.
- `workspace_read_file` refused `.env` with a deny-list message. Twelve tools had no such check: `zts_check`, `pi_specs_status`, `gen_tests`, `pi_goal_check`, `pi_goal_candidate`, `pi_repair_plan`, `pi_apply_repair_plan`, `zts_expert_holes`, `zts_expert_fill_hole`, `zts_expert_effects`, `zts_expert_narrow`, and `zts_expert_ast_rewrite`. `workspace_list_files` also skipped it, but it returns names, not content.
- No test failed. Each tool that had the check had a test, and no test asked the other tools for a secret path.

## What Didn't Work

- **A check at each call site.** Round 3 (item H2) added the deny list to `ignoredRefusal` and a post-filter in search. That closed the two tools that read or search text. It left every other caller of `resolveInsideWorkspace` open, and each new tool would have needed the same line.
- **A probe with the obvious secret files.** Pointing the analyzer tools at `.env`, `server.pem`, or `signing.key` showed no leak. `admitToolSource` in `packages/pi/src/tools/common.zig` refuses a path with an unsupported extension before it parses anything. That extension gate hid the gap. The leak needs a file that is both secret-named and `.ts`, for example `.env.local.ts`, or a `.ts` file under a directory such as `.env.d/`.
- **A basename check.** The first deny list read the last path component only. A file under a secret-named directory passed it.

## Solution

Enforce the deny list once, in the function that every tool already calls to turn a model path into a file path.

`resolveInsideWorkspace` in `packages/pi/src/tools/common.zig` now refuses with `error.SecretPath` when the part of the path below the workspace root matches `isSecretPath`. It checks that part twice: as the model named it, and as it resolves through symlinks.

```zig
const canonical = try resolveCanonicalTargetInsideWorkspace(allocator, root_real, resolved);
errdefer allocator.free(canonical);
// The deny list reads the path below the root both as named and as resolved,
// so a symlink can neither hide a secret nor rename one.
if (isSecretPath(relativeToRoot(lexical_root, resolved)) or isSecretPath(relativeToRoot(root_real, canonical))) {
    return error.SecretPath;
}
return canonical;
```

`isSecretPath` applies `isSecretBasename` to every component, so `config/.env.d/prod.txt` is refused.

The tool error reaches the model through one function, `invokeToolRecovering` in `packages/pi/src/loop.zig`. It now renders `error.SecretPath` as the deny-list refusal, so the model gets a clear message and no file content:

```zig
error.SecretPath => registry_mod.ToolResult.errFmt(
    allocator,
    "{s}: path matches the secret file deny list and is not readable",
    .{call.name},
),
```

The per-tool check in `ignoredRefusal` is gone. The search post-filter stays, because search records come from `rg` or the in-process walk and do not pass through the resolver.

## Why This Works

The defect was a rule at the wrong depth. A rule that guards a boundary must sit at the point every crossing passes. `resolveInsideWorkspace` is that point for model-supplied paths: each tool, the change-set preparation, and the proof snapshot call it. A check there covers the twelve open tools, every future tool, and an edit that tries to write a secret-named file.

Two details keep the check correct:

- It reads only the part of the path below the root. A workspace that itself sits under a directory such as `.env.d/` still works.
- It reads the path both as named and as resolved. A link `notes.ts -> .env.prod.ts` is refused, and so is a link with a secret name that points at an ordinary file.

## Prevention

- Put an access rule in the shared resolver, not in each tool. When a new tool needs a path, it calls `resolveInsideWorkspace` and inherits the rule.
- Probe the input that passes every earlier gate. A probe with `.env` stopped at the extension gate and proved nothing about the deny list. The probe that found the leak used a file that was both secret-named and `.ts`.
- Assert at the layer the model sees. The loop test "a secret path reaches the model as the deny-list refusal, not its content" calls `invokeToolRecovering` and checks that the text names the deny list and does not hold the secret. It fails when the `error.SecretPath` branch is removed.
- The resolver test "resolveInsideWorkspace: refuses a secret path, also through a symlink" covers a secret file, a secret directory component, and a symlink to a secret file.
- `packages/pi` has no gate that finds a per-tool rule that some tools skip. The AGENTS.md note that this fail-open class "also shipped in `packages/pi`, where no such gate exists" now has a second example.

## Related Issues

- [An empty baseline made a file-destroying edit prove clean](../logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md): another `packages/pi` fail-open, where a check did not cover one tool path.
- [A dispatched route was never walked, so its leak proved clean](a-dispatched-route-was-never-walked-so-its-leak-proved-clean.md): the same shape in the flow checker, where coverage at some call sites left others unchecked.
- [An empty label set claimed a value was clean](empty-label-set-claimed-a-value-was-clean.md): the probe method of sending a labelled value through each new path.

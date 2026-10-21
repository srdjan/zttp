# Hand-off: completeness audit and soundness fixes, 2026-10-21

Status at hand-off: five fixes are committed on local `main`, and nothing is
pushed. Two soundness units (U2 and U3) are specified and approved, but they
are not validated and not implemented. The owner stopped the session during
the validation of U2 and U3.

## Source documents

| Document | Content |
|---|---|
| [Completeness audit](2026-10-21-completeness-audit.md) | About 100 findings from four research agents, with a Fable validation verdict for each finding (section H) |
| [Quick-fixes plan](2026-10-21-quick-fixes-plan.md) | Plan for Q1 to Q3, with the codex corrections |
| [Soundness plan](2026-10-21-soundness-plan.md) | Plan for U6 and U1 (with the codex corrections), and the full U2 and U3 specification |

The audit cites probe files under a session scratchpad directory. That
directory is not in the repository. A later session must write new probes from
the descriptions in the audit.

## Completed work

| Commit | Unit | Change |
|---|---|---|
| `b7501d4c` | Q1 | Six version copies now equal `VERSION` 0.23.0. Before this commit, `zig build test` failed on `release_check`. |
| `6f58ad43` | Q2 | `zttp proofs verify` gives the bundled policy section to acceptance. Before this commit, every guarded artifact was rejected with `runtime_policy_missing`. |
| `ece05117` | Q3 | `compile`, `build` and `deploy` run production acceptance before they write the artifact. A refused build writes no file and exits 1. |
| `479ca48f` | U6 (S6) | The checker requires the trusted opcode edge for every totality claim. Before this commit, a certificate without translation evidence was accepted at grade `proved`. Mutant EVD21 is new. |
| `e5de5586` | U1 (S1, S4) | Inside a function body, `sql()` and `schemaCompile()` need a static argument 1, otherwise ZTS602 is reported. Module scope accepts any expression. Only direct calls are detected. |

Checks for these commits:
- After Q3 and after U1, `zig build test`, `zig build test-zruntime` and `zig build check-spine` exited 0.
- After Q3, `test-server`, `test-examples`, `smoke-v1` and `smoke-getting-started` also exited 0.
- Each unit also passed its own named gates.
- For each new test, the implementer reverted the fix and saw the test fail.

## Owner decisions on record

- D1(a), D2(a): do the quick fixes first. The workflow is: Opus plans, Fable or codex validates, Sonnet implements, and Opus reviews and commits.
- Group (b): do the soundness group next.
- D3(a): every literal `env()` name is `secret`. A new policy field `env.public` lowers the listed names to `config`.
- D4(a): `mask` declassifies only when the bound is a literal of 4 or less and the input is the unmodified result of a labelled source.
- D5(a): the registration rule covers both `sql()` and `schemaCompile()`. This decision is done in U1.
- D6(a): U2 and U3 land now. The codegen replay in `test-expert-app` is then expected to fail with `StaleCodegenCassette`, and so is `zig build test`, until the owner triggers a DeepSeek re-record. This follows commit `b7037cb8`.
- D7(a): there is no rule that an `env.public` name must also be in `env.allow`.
- D8(a): when `env.public` is not empty, the contract JSON discloses it.

## Current work at the stop

A codex `gpt-6-astra` read-only validation of U2 and U3 was running, and I stopped it. Its partial output was in the session scratchpad and is not kept here. The validation must run again from the beginning.

## Remaining work, in order

1. Validate U2 and U3 in the soundness plan with Fable, or with codex `gpt-6-astra` if Fable is rate-limited. Run every `codex exec` with `< /dev/null`. The validation prompt must check:
   - every policy-bearing path that runs analysis without `env_public`;
   - every copy or combination path in `flow_interp.zig` where `source_exact` survives a transformation;
   - the `valueEql` fixpoint requirement;
   - hash pins and goldens that the plan does not name;
   - the two-commit version split (flow analyzer version 8, then 9).
2. Resolve each validation finding in the plan, or record why it is rejected.
3. Send U2, then U3, to a Sonnet implementer. Each unit is one commit. Neither unit may call a hosted model provider.
4. Review each diff line by line. Run the gates listed at the end of the soundness plan, then `zig build test`, `test-zruntime` and `check-spine`. In `test-expert-app`, the only accepted failure is `StaleCodegenCassette`.
5. Update this index and `docs/roadmap.md` when U2 and U3 close.

## Open items for the owner

- **Push:** the five commits above are local only.
- **CHANGELOG:** `CHANGELOG.md` has no entry for 0.22.4, 0.23.0, or the five fixes. The U2 and U3 specification adds `[Unreleased]` entries for those two units only.
- **Re-record:** a DeepSeek re-record of the codegen corpus is required after U2 and U3, before the next release. After it, republish the coverage and convergence evidence. `zig build release-provenance` already fails on 251 stale paths.
- **Remaining audit groups:** not selected yet. The largest groups in the audit are:
  - HTTP server defects: header bare-LF smuggling, recursion crash, idle-socket starvation, the static-directory response.
  - `zttp dev` defects: empty environment, orphaned child.
  - Per-slot cache and rate stores.
  - Language semantics: float formatting, string length, unknown members.
- **Recommended solution notes:** record two lessons with `ce-compound`:
  - Q3: the build path ran no production acceptance.
  - S2: the env label came from a name heuristic.

## Method notes

- In this shell, `curl` is an alias for `curlie`. Use `command curl`.
- `diff` is also aliased. Use `command diff`.
- Agent worktree isolation branches from `origin/main`. Use the main working tree.
- Subagents cannot write report files. Save their text from the main session.

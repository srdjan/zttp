---
title: Find dead code in a Zig monorepo with an identifier-frequency census
date: 2026-07-31
category: tooling-decisions
module: repo-wide (zts, runtime, tools, pi, modules)
problem_type: tooling_decision
component: tooling
severity: medium
applies_when:
  - "Auditing this repo for unreferenced functions, constants, types, or files"
  - "Deciding whether a pub declaration in Zig is genuinely unreachable"
  - "Removing code that spans several packages behind the module-boundary gate"
tags:
  - zig
  - dead-code
  - static-analysis
  - refactoring
  - module-boundary
  - lazy-analysis
---

# Find dead code in a Zig monorepo with an identifier-frequency census

## Context

No dead-code analyzer exists for Zig. `zig build` reports unused locals and
unused function parameters, but it says nothing about a `pub fn` that no
caller names, and nothing about an unused container-level `const`. The
generic helper `scripts/find-dead-code.sh` shipped with the refactor skill
detects knip, ts-prune, vulture, clippy, and friends; against this repo it
exits 1 with "no dead-code analyzer found for this project".

Scanning 459 tracked `.zig` files, 268k lines, by hand is not viable, and the
naive approach of grepping the whole corpus once per declaration does not
finish: a first attempt at roughly 3,000 declarations x one corpus grep each
exceeded a 600-second timeout.

## Guidance

Build the frequency table once, then join declarations against it. One pass
over the corpus instead of one pass per declaration turns a timeout into a
few seconds.

```bash
# 1. Count every identifier across all tracked sources, once.
git ls-files -z '*.zig' | xargs -0 cat \
  | grep -oE '[A-Za-z_][A-Za-z0-9_]*' \
  | sort | uniq -c | awk '{print $2" "$1}' | sort > freq.txt

# 2. Extract declarations as "name file:line", sorted on the name.
git ls-files -z '*.zig' | xargs -0 grep -Hn -E '^[[:space:]]*(pub )?fn [A-Za-z_][A-Za-z0-9_]*\(' \
  | sed -E 's/^([^:]+):([0-9]+):[[:space:]]*(pub )?fn ([A-Za-z_][A-Za-z0-9_]*)\(.*/\4 \1:\2/' \
  | sort -k1,1 > fns.txt

# 3. A count of 1 means the name occurs exactly once in the whole corpus:
#    its own declaration. Nothing references it.
join fns.txt freq.txt | awk '$NF==1'
```

A count of 1 is a strong signal, not a heuristic. Because the table counts
raw identifier occurrences, it also rules out re-exports: `pub const foo =
mod.foo;` would raise the count to 3. Swap the `grep -E` pattern to census
other declaration kinds - `const NAME = ` for constants, `const NAME =
(packed |extern )?(struct|enum|union)` for types, indented `name: Type,` for
struct fields, bare `name,` for enum variants.

Use BSD-compatible shell. macOS `xargs` has no `-a` flag; feed file lists
through a pipe or `-0`.

Four rules make the results trustworthy:

**Run the census again after every removal round, and repeat to fixpoint.**
The first pass only finds code with zero references. A function kept alive by
a single dead caller still scores above 1 and hides. Each deletion round
orphans the next layer.

**Never trust an uncalled Zig function to compile.** Zig performs lazy
semantic analysis: a `pub fn` that nobody calls is never analyzed, so it can
reference symbols that do not exist and the build still passes.

**Confirm cross-package reach with the boundary gate, not by eye.**
`scripts/check-module-boundary.sh` fails in both directions - an unlisted
reach fails, and a row in `scripts/module-boundary.allow` that nothing uses
fails too. Removing the last consumer of a `zts` internal module from
`runtime`, `tools`, or `pi` turns that row stale and reddens the gate. Prune
the row in the same commit and read the gate's own counts back as proof.

**Separate mechanical deletions from judgment calls.** Wire-format fields,
`packed struct` bits, and documented deferrals score exactly like accidental
leftovers. Classify before cutting; see "When to Apply".

## Why This Matters

The census found 103 unreferenced functions and 14 unreferenced constants in
a repo whose build, full test suite, and CI gate were all green. Removing
them and sweeping to fixpoint deleted 1,615 lines across 50 files with zero
insertions and no behavior change.

More valuable than the line count: the census surfaced defects that a green
build cannot.

`packages/zts/src/context.zig` carried `clearCompiledCodePointers`, which
called `self.clearCompiledCodeRecursive(...)` twice. That method had no
definition anywhere in the tree - the only copy lived in an untracked
`.worktrees/` checkout. The build was green solely because nothing called the
outer function. Anyone who wired it up would have hit a compile error on code
that looked long-settled.

The field-level census surfaced a second class: config knobs that silently do
nothing. `ContextConfig.init_globals`, `ServerConfig.pool_metrics_every`
(documented as "Log pool metrics every N requests"), three `GCConfig` tuning
fields, and `PolicyInput.args_hash` are all declared, settable, and never
read. `LocalPolicyChecker.check` consults `resource`, `action`, and
`env.service` - a caller can pass an args hash and policy ignores it. These
are worse than dead code: they are an API that lies to its caller.

A third class is documented conventions nobody adopted. `rule_error.zig`
declared `RuleError` with a module doc stating that four named subcommands
use it "instead of anyerror". None did. One aliased the module without ever
naming the set; three never imported it.

## When to Apply

- Before a cleanup pass, to size the work with evidence instead of intuition
- After removing any batch of code, until the census returns empty
- When a doc claims a convention is in use and you want to verify it
- Not as a delete-everything list. Classify each hit first:

| Class | Example | Action |
|---|---|---|
| Accidental leftover | superseded helper, orphaned wrapper | delete |
| Rot hidden by lazy analysis | calls a symbol that does not exist | delete, commit as `fix` |
| Wire or on-disk format | `BytecodeHeader.version_minor`, `BytecodeFlags.has_source_map` | keep, removal breaks the format |
| Packed-struct bit | any field in a `packed struct(u8)` | keep or replace with `_reserved`, never just delete |
| Public config field | `ContextConfig.init_globals` | report, removal is an API change |
| Documented deferral | `AtomTable.pruneUnused` | keep, a written decision parked it |

## Examples

**Retiring a bit from a packed struct.** `Heap.setRemembered` and
`getRemembered` were dead, leaving `is_remembered` written by nobody. It
could not simply be deleted - `MemBlockHeader` is declared `packed
struct(u32)` and the bit widths must still sum to 32. Measure rather than
assume, per the repo's rule against guessing numbers:

```zig
// A throwaway program printing @sizeOf for both shapes, before and after.
// Measured: MemBlockHeader stays 4 bytes either way; the ordinary
// LargeHeader struct stays 32 bytes with the field removed outright.
```

The result: a named `_reserved: u1` in the packed header, an outright
deletion in the plain struct, and a commit message stating the measurement
instead of asserting the change was safe.

**Proving there are no unreachable files.** A basename grep for
`@import("ratelimit.zig")` misses `@import("data/ratelimit.zig")` and reports
40 false positives. Walk the real graph instead: collect roots from every
`build.zig`'s `.path("...zig")` plus each package's `root.zig` and test
roots, then BFS over `@import` targets resolved relative to the importing
file's directory. That returned 450 of 450 sources reachable, with only the 8
`build.zig` scripts unreached - a definitive answer rather than a noisy list.

**Reading the gate as evidence.** Deleting the `rule_error` module dropped
`zig build test-module-boundary` from "76 internal modules, 101 allowed
package reaches" to "75 internal modules, 100 allowed package reaches",
confirming exactly one module and one allowlist row went away.

**Distinguishing a pre-existing log line from a regression.** `zig build
test-zruntime` prints `failed command: ...` next to a WebSocket timeout
warning while exiting 0. Rather than assume, `git stash` the working changes,
rerun, and compare: identical output on the untouched tree, so it is the
suite exercising `recycleAfterTimeout`, not a new break.

## Related

- [Balance a rich ZTS surface with a small certified kernel](zts-rich-surface-small-kernel.md)
- `scripts/module-boundary.allow` and `scripts/check-module-boundary.sh` - the two-directional reach gate
- `scripts/verify.sh` - the full local gate mirroring CI
- `docs/internals/testing.md` - which `zig build test*` step covers what

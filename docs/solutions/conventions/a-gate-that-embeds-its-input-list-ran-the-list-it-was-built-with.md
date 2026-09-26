---
title: A gate that embeds its input list ran the list it was built with
date: 2026-09-25
category: conventions
module: packages/tools (proof-checker mutation gate runner and mutant list), build.zig (test-proof-checker-mutants run step), repo-wide (any gate that compiles in a data file it does not own)
problem_type: convention
component: testing_framework
severity: high
applies_when:
  - "Wiring a gate whose input is a data file (a mutant list, a corpus, a registry, an allowlist) and choosing between @import-ing it and reading it at run time"
  - "Editing a gate's input list and reading the next run as evidence about the edited list"
  - "A gate names a row, an id, or a count that no file in the tree contains any more"
  - "Deciding whether a stale-looking verdict comes from the input or from the build cache, before reading the gate's source"
  - "Hand-running one mutant or probe outside its runner and reading a nonzero exit as killed rather than as did-not-compile"
tags:
  - testing
  - build
  - gates
  - mutation-testing
  - build-cache
  - zon
  - fail-open
  - probes
---


# A gate that embeds its input list ran the list it was built with

## Context

`zig build test-proof-checker-mutants` applies each row of `packages/tools/src/proof_checker_mutants.zon` to a private copy of the acceptance kernel, compiles the kernel's suite, runs it, and fails when a mutant survives, when a row no longer matches the source, or when a row marked equivalent is killed (`docs/internals/testing.md:333-341`). The runner is `packages/tools/src/proof_checker_mutants.zig`, wired in `build/proof_gates.zig` under the `test-proof-checker-mutants` step.

As introduced in commit `81cd5896`, the runner held its list at compile time:

```zig
const mutants: []const Mutant = @import("proof_checker_mutants.zon");
```

On 2026-09-25 the list was edited in the working tree: twelve rows deleted, thirteen added, 254 rows to 255. The gate was rebuilt and run. It ran 254 rows. It reported:

```
row INV25 no longer applies - re-anchor it (found 0 matches)
```

No file in the repository contained `INV25` any more. A grep over `packages/` and `build.zig` found nothing, and the current list steps from `INV24` to `INV26`. The gate was reporting a row from a list that no longer existed. Running `touch` on the `.zon` and rebuilding changed nothing. A build with a fresh `--cache-dir` ran 255 rows and gave the correct verdict: one real failure, a row whose mutation did not compile.

Those are the measured observations, on the Zig 0.16.0 toolchain this repository builds with. What was not isolated is the mechanism: which cache entry held the stale product, or whether a `.zon` reached through `@import` is tracked as an input of the compile step at all. This document makes no claim of a Zig defect. It records that the build product was stale under those steps and that a fresh cache directory was not, and it draws its rule from the part that does not depend on the mechanism.

The list edit was uncommitted when the fix landed. The committed list carries 254 rows at `f5e94184` and 257 rows at `HEAD`, counted as occurrences of `.id = "`.

## Guidance

**A gate whose input is data reads that data at run time, through a build-tracked file argument, and never compiles it into its own binary.**

The list is now the runner's third argument. The build passes it with `addFileArg`, beside the compiler path and the kernel directory (`build/proof_gates.zig`, `proof_checker_mutants_cmd`):

```zig
proof_checker_mutants_cmd.addArg(b.graph.zig_exe);
proof_checker_mutants_cmd.addDirectoryArg(proof_checker_dep.path(""));
proof_checker_mutants_cmd.addFileArg(tools_dep.path("src/proof_checker_mutants.zon"));
```

The runner takes the path (`packages/tools/src/proof_checker_mutants.zig:74`) and loads it into an arena before anything else runs (`:77-79`). `loadList` reads the file and parses it into the same typed schema the `@import` used (`:564-574`):

```zig
fn loadList(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const Mutant {
    const source = std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(16 * 1024 * 1024), .of(u8), 0) catch |err| {
        std.debug.print("proof-checker mutants: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    var diag: std.zon.parse.Diagnostics = .{};
    return std.zon.parse.fromSliceAlloc([]const Mutant, arena, source, &diag, .{ .free_on_error = false }) catch |err| {
        std.debug.print("proof-checker mutants: {s} is not a valid mutant list:\n{f}", .{ path, diag });
        return err;
    };
}
```

The argument for this shape does not need the cache mechanism. Whatever binary the build hands to the Run step, that binary opens the list in the tree and parses it. A stale runner can no longer carry a stale list, because the list is not in the runner. The `var mutants` declaration and the comment above it state the measurement that motivated the change (`:17-20`).

**Keep the typed schema when the input moves to run time.** The `Mutant` struct (`:9-15`) is the same one the `@import` filled. A malformed row now fails at load with a location instead of at compile time, and `Diagnostics` prints it. The floor over the loaded list is unchanged: an empty list fails (`:272-274`), and every row must carry an id, an anchor, a valid file, and a non-empty equivalent reason where it claims one (`:277-292`).

**Print the input count on every run.** The runner reports `running {d} rows` before it starts a worker (`:129-132`). That line was the only visible sign that the gate held a different list from the tree. A count that does not match the file you just edited is the earliest and cheapest signal this class gives.

**`has_side_effects` reruns the executable. It does not rebuild it.** The Run step already carried `has_side_effects = true` before the fix (`proof_checker_mutants_cmd.has_side_effects` in `build/proof_gates.zig`). The comment on the invariant drift gate states what that flag covers (the "`has_side_effects` is load-bearing" comment in `build/proof_gates.zig`): a Run step is cached on its executable and its arguments, never on the files the program reads at run time, so a gate that reads files at run time needs the flag to rerun. This document is the other half of that pair. The flag reruns whatever executable the compile step produced, and when the executable itself is stale, rerunning it reruns the stale list. A file argument places the list on the run side, where the flag and the argument tracking both apply.

**When a gate reports an item that the source no longer contains, suspect a stale build product first, and confirm with a fresh `--cache-dir`.** A row that does not exist cannot be re-anchored. The instruction in the message was correct for a live row and impossible for this one, and that impossibility is the diagnostic. The confirmation is one command with an empty cache directory. If the fresh build gives a different count or a different verdict, the input the gate held was not the input in the tree, and no amount of re-reading the gate's source will show it.

## Why This Matters

The three gate conventions this repository already holds cover an input that has gone empty ([a gate that counts nothing still reports a pass](a-gate-that-counts-nothing-still-reports-a-pass.md)), an assertion or a probe that is weaker than it looks ([difference is not the claim, and a probe must compile](difference-is-not-the-claim-and-a-probe-must-compile.md)), and a gate that passes every named probe and is still porous ([a gate can be non-vacuous and still porous](a-gate-can-be-non-vacuous-and-still-porous.md)). This runner satisfied all three. It has a floor on the list, a floor on the suite's test count, a per-row validity check, and a row count in its output. The count was 254, the list was full, and the verdict was wrong, because a floor guards the input the gate holds and says nothing about whether that input is the one in the tree.

The symptom that exposed it was a reported failure. It could as easily have been a reported pass. Thirteen new rows were written to show that the suite could see thirteen changes to the kernel. Under the stale binary none of them ran, and if the twelve deleted rows had still matched the source, the gate would have printed a green report over a list nobody could find in the repository. That report would then have been cited as evidence that the new rows were killed. A stale gate does not fail loudly. It answers yesterday's question with today's confidence.

The same gate had already learned a narrower version of this lesson on the day it was introduced. `docs/internals/testing.md:340-341` records that a reused cache gave stale verdicts at the mutant level, which is why each row now compiles with its own `--cache-dir` (`packages/tools/src/proof_checker_mutants.zig:360-369`). That fix moved the cache one level down and left the level above it, the runner's own build, untouched.

## When to Apply

Whenever a gate's verdict depends on a corpus, an allowlist, a marker list, a mutant list, a registry, or any other data the gate does not compute for itself. Pass that data as a file argument of the Run step and read it in `main`. Do not `@import` or `@embedFile` it into the gate's executable.

Whenever a gate prints a count. Compare that count against the file you edited before reading anything else in the output.

Whenever a gate names an item you cannot find. Search the tree once, and if the item is absent, rebuild with a fresh `--cache-dir` before you re-anchor, delete, or explain anything.

Not needed for a fixed literal in the gate's own source file, where a change to the input is a change to the source the build already tracks, and where a stale product would be visible as a diff that did not take effect.

## Examples

The freshness probe, run after the fix and without a rebuild. Append one line to the list:

```
garbage
```

The next `zig build test-proof-checker-mutants` fails at load at once:

```
257:2: error: expected 'EOF', found 'an identifier'
```

No rebuild happened between the edit and the failure. The runner read the file it was handed, and the parser refused it with a location. The line was then removed and the list restored. Under the pre-fix `@import`, the same edit would have been a compile error in the runner, subject to whatever the compile step's cache decided to notice.

The compile-versus-run separation, which the same session touched. A hand-run of the one row that did not compile, made by a subagent as `zig test` over the mutated copy, reported that mutant as killed. A compile error and a failing test both exit nonzero, and the hand-run read the exit code as a kill. The runner does not make that mistake. It compiles the suite first with `--test-no-exec` and `-femit-bin` (`packages/tools/src/proof_checker_mutants.zig:365-369`), classifies a nonzero exit there as `no_compile` (`:383-388`), and only then runs the emitted binary and reads killed or survived from its exit (`:390-405`). The header comment states the reason (`:3-5`). The general rule, that a probe which does not compile has run no check, is in [difference is not the claim, and a probe must compile](difference-is-not-the-claim-and-a-probe-must-compile.md); the runner is that rule built into the harness so a reviewer does not have to remember it per row.

## Related Issues

- `CONCEPTS.md`, the Gate and Probe entries under "Guarding the repo" - the whole class in one place; this document adds a fourth failure shape to it, the stale input
- [a-gate-that-counts-nothing-still-reports-a-pass](a-gate-that-counts-nothing-still-reports-a-pass.md) - the floor-on-input rule this runner already satisfied while running the wrong input
- [difference-is-not-the-claim-and-a-probe-must-compile](difference-is-not-the-claim-and-a-probe-must-compile.md) - the probe-must-compile and exit-code rules, which the runner's compile-then-run split implements per row
- [a-gate-can-be-non-vacuous-and-still-porous](a-gate-can-be-non-vacuous-and-still-porous.md) - the mutation method this gate exists to apply to the kernel
- `docs/internals/testing.md:333-341` - the gate's entry, including the earlier stale-cache finding at the mutant level
- `build/proof_gates.zig`, the "`has_side_effects` is load-bearing" comment - states what the flag covers, and by omission what it does not
- Commit `f5e94184` - the fix: file argument in `build.zig`, `loadList` in the runner
- Commit `81cd5896` - the gate as introduced, with the `@import`

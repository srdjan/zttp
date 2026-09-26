---
title: A file split proven by its graph broke the gates that read it as text
date: 2026-09-26
category: conventions
module: build.zig and build/*.zig (step wiring), packages/tools (invariant drift gate), tooling (release check), scripts (verify.sh and the shell gates that parse build files), repo-wide (moving, splitting, or renaming any file a gate reads by path or pins by line)
problem_type: convention
component: testing_framework
severity: medium
applies_when:
  - "Moving, splitting, or renaming a file that a gate reads by path or greps for an exact line: build.zig, verify.sh, a registry, an allowlist, a workflow"
  - "Proving a refactor behavior-preserving by comparing its product (a step graph, a binary, a hash) and reading that proof as covering the whole refactor"
  - "Searching for a file's consumers and stopping at shell scripts, at one package tree, or at the first page of grep output"
  - "Editing a line in a script or build file that another gate carries as a marker string"
  - "A Run step exits nonzero and the build log carries no reason"
tags:
  - testing
  - build
  - gates
  - refactoring
  - verification
  - fail-closed
  - markers
  - text-consumers
---

# A file split proven by its graph broke the gates that read it as text

## Context

Commit 11d3a74d split `build.zig`, one function of about 1800 lines, into thirteen files under `build/`, and made `build.zig` an orchestrator that calls them in order. The refactor came with a proof that the step graph did not change. `zig build -l` and `zig build -h` were byte-identical before and after. A temporary probe hashed the dependency closure of every top-level step, Merkle-style, over step kind, step name, Run argv, `has_side_effects`, stdio checks, compile root, import count, filters, and strip, and the hashes matched with default options and with `-Dhandler -Dverify -Dcontract -Dsystem -Dstrip`. The same commit updated the four shell gates that parse the build file as text (`check-docs-drift.sh`, `check-zts-layering.sh`, `check-residual-guards.sh`, `check-script-reachability.sh`), the `zig fmt --check` paths, the `.paths` list in `build.zig.zon`, and the line references in the docs.

`bash scripts/verify.sh` then failed. The build log said that `test-invariant-drift` -> `run exe invariant-drift-gate` exited 1, and gave no reason. Running the gate binary directly from the repository root printed the reason in one line: `application invariants: build_step_missing: build.zig declares no test-invariant-drift step`.

Two Zig programs read `build.zig` as text, and the split updated neither:

- `packages/tools/src/invariant_drift_gate.zig` names one file as its `.build` input. Its `validate` scans that text for the `b.step("test-invariant-drift"` declaration, the `b.addRunArtifact(invariant_gate_exe)` binding and its `has_side_effects = true` line, a floor of five `invariant_drift_step.dependOn(` edges, and the exact edge `invariant_drift_step.dependOn(&run_cli_tests.step)`. Three mutation probes (`probeBuild`, `probeBuildEvidenceRoot`, `probeBuildReplacedGate`) edit that same text. After the split, that wiring was spread over `build/proof_gates.zig`, `build/host_tests.zig`, and `build/runtime_tests.zig`.
- `tooling/release_check.zig` searched its `build_gate_markers` (step names) in `build.zig` alone, and its `verify_script_markers` pinned the exact text `zig fmt --check build.zig packages/`, which the split had edited in `scripts/verify.sh` to add `build/`. `zig build release-check` reported `[fail] Release gates`. Nothing in `scripts/verify.sh` runs `release-check`, so this second break was silent locally. It was found only because the first one started a wider search.

This is the second time `release_check.zig` broke this way. On 2026-09-09, commit 523f68a1 repaired it after commit 4d287b56 removed the `bash scripts/test-examples.sh` line from `verify.sh`: a marker pinned a line, the line was edited for a good reason, and `release_gates` went to `fail` for a gate that was in fact wired.

The graph proof was correct. It proved what it said, and the two gates that broke never look at the graph. A text reader consumes bytes at a path, and a split moves bytes away from paths without changing the graph at all.

The reader search before the split was also incomplete, in two ways that both fail silently. It grepped `scripts/`, `.github/`, and `packages/*/src` for `build\.zig`, so it never looked at Zig sources under `tooling/`. And it piped the listing through `head`, so even a covered root could lose hits past the first page. It found the four shell readers, and that success gave false confidence: a search reports what it found and has no signal for what it did not look at.

## Guidance

**A behavior-identity proof covers the product, not the readers of the source.** Keep the graph proof for build refactors, and then enumerate the text consumers separately. Before you move, rename, or split a file, run two searches and read the whole of each listing.

1. **The path as a quoted literal**, across every tracked source:

   ```bash
   git grep -n '"build\.zig"'
   ```

   Run against the tree before the split, this lists both readers that broke: the `.build = "build.zig"` input in `invariant_drift_gate.zig` and the `readOptionalFile(allocator, "build.zig", ...)` call in `release_check.zig`. It also lists hits that are not readers of this repository's build file, and each one must be triaged by reading: the scaffold template in `packages/runtime/src/init_command.zig`, path tests in `packages/pi/src/loop.zig` and `tooling/production_branch_metric.zig`, a file-access test in `packages/zts/src/module_binding.zig`, a fixture in `release_check.zig`, and the `.paths` entry of every `build.zig.zon` (those last appear only when the search is not restricted to `*.zig`). The listing is a candidate set, not a verdict. Never truncate it. For shell, awk, and YAML, search the bare path as well, because those files may not quote it: two of the four shell readers here did not.

2. **The exact old text of every line you edit**:

   ```bash
   git grep -nF 'zig fmt --check build.zig packages/'
   ```

   Before the split this listed the `verify_script_markers` entry and two test fixtures in `release_check.zig`, next to `ci.yml` and `verify.sh`. The quoted-literal search cannot find that marker, because the path sits inside a longer string. A marker that pins a line is found only by searching for the line.

**Fix each reader in the direction its contract points.** The two readers here needed opposite fixes:

- The drift gate's contract is single-file by construction. It counts `dependOn` edges in one text and refuses fewer than five, requires one named edge in that same text, and `probeBuildEvidenceRoot` rewrites that exact line to prove the check is live. Pointing `.build` at a new file without moving the edges would clear `build_step_missing`, and the five edges already in that file would satisfy the count, but the missing named edge would fail `build_evidence_dependencies` and leave the probe with no anchor. So the wiring moved to the reader. Every `invariant_drift_step` edge now lives in `build/proof_gates.zig`, and a new `addInvariantDriftEvidence` there adds the three roots that other files create. `build.zig` calls it after those roots exist, in the original edge order, so the closure hashes do not move. The gate's `.build` input names `build/proof_gates.zig`, and its messages print `paths.get(.build)` instead of a literal path.
- `release_check.zig` only looks for markers anywhere in the build, so the reader widened to the subject. `readBuildSources` reads `build.zig` and then every `.zig` file under `build/` by directory iteration, so a new build file needs no edit there. A test writes a `build.zig` that names no gate, puts every marker under `build/`, and asserts that every build gate marker is still found.

Commit 9da66818 holds both fixes. After it, the gate reports that its 83 mutation probes reject, and `bash scripts/verify.sh` passes.

**State the single-file constraint where the next editor will touch it.** A comment above `addInvariantDriftEvidence` says that the drift gate reads that file as text and its probes edit it. A gate that reads one file stays simple only while that file is the unit the author moves.

**When a Run step exits 1 with no reason, run the gate binary directly.** The gates here print their rejection to stderr with the check name and the file they read, and that line names the fix. `zig build invariant-gate` installs the drift gate on its own for this purpose.

**After a change to build wiring, `verify.sh`, or a workflow, also run `zig build release-check`** and read the `Release gates` row, because `verify.sh` does not run it.

## Why This Matters

Both breaks fail closed, so neither shipped a false pass. The cost is elsewhere. A refactor that arrives with a strong proof of identity invites the reviewer to stop there, and the proof is exactly as wide as its subject. The first break surfaced only in the full gate, after a commit. The second surfaced only because someone went looking, and on the default local path it would have stayed red until a release run.

The class recurs. `release_check.zig` has now broken twice through one mechanism: a marker that pins a line another commit edits for a good reason. The drift gate is the case that `a-gate-can-be-non-vacuous-and-still-porous.md` already names as coupled to spelling, and a file split is honest refactoring that trips it closed. Line-number citations into `build.zig` in the docs went stale in the same way, and had to be repointed after earlier merges shifted the file (session history). A search that covers only the reader types you remember will miss the next one of these.

## When to Apply

- Before moving, renaming, or splitting any file that gates, tooling, or docs name: the build files, `scripts/verify.sh`, an allowlist, a registry, a workflow.
- Before editing a line in a script or build file, when the line looks like a command another gate might check for.
- When you cite a graph, binary, or hash comparison as the evidence that a refactor is safe.
- When a Run step fails with no message in the build log.

## Examples

**The two searches on the pre-split tree.** `git grep -n '"build\.zig"'` found both Zig readers along with non-reader hits that needed triage. `git grep -nF 'zig fmt --check build.zig packages/'` found the pinned marker that the first search could not. Together they would have found both breaks before the split commit.

**Moving the next file.** At HEAD, the drift gate's literal is `"build/proof_gates.zig"`, so `git grep -n '"build\.zig"'` no longer lists it. Whoever moves or splits `build/proof_gates.zig` must search for `'"build/proof_gates\.zig"'`. That search lists the gate's `.build` input. The rule is to search for the name of the file you are moving, not for the name the last incident used.

**Making the graph proof trustworthy.** The closure-hash probe first looked nondeterministic, because Zig passes a random `--seed=` argument to every test Run step, so the probe must skip that argument. After a commit, the `-Dhandler` graph differed from the baseline, because the precompile step receives `--git-commit <HEAD>`. Hashing the old and new build at the same HEAD showed identical graphs. Neither difference was a defect in the split, but each one had to be explained before the proof could be read as evidence.

## Related Issues

- [a-gate-can-be-non-vacuous-and-still-porous.md](a-gate-can-be-non-vacuous-and-still-porous.md): the same drift gate. Its mutation probes are why the wiring had to stay in one file.
- [a-gate-that-embeds-its-input-list-ran-the-list-it-was-built-with.md](a-gate-that-embeds-its-input-list-ran-the-list-it-was-built-with.md): a gate that read a stale copy of its input. Here the gate read the right copy of an input that no longer held what it scanned for.
- [difference-is-not-the-claim-and-a-probe-must-compile.md](difference-is-not-the-claim-and-a-probe-must-compile.md): read a verdict from the exit status. Here the exit status was 1 and the reason was only on the binary's stderr.
- [a-guard-that-every-input-satisfied-refused-the-first-new-one.md](a-guard-that-every-input-satisfied-refused-the-first-new-one.md): `test-step-coverage` walks the live graph rather than the source, which is why the split could not break it.

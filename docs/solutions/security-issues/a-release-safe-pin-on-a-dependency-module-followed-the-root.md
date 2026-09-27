---
title: A ReleaseSafe pin on a dependency module followed the root
date: 2026-09-26
category: security-issues
module: proof acceptance
problem_type: security_issue
component: tooling
symptoms:
  - "Root ReleaseFast with a ReleaseSafe dependency module: `unreachable` and an out-of-bounds index inside the dependency ran to exit 0 and returned a garbage byte."
  - "Root ReleaseSafe with a ReleaseFast dependency module: both sites panicked, so safety followed the root module and not the dependency's .optimize."
  - "The release zttp and zttp-runtime executables ran the acceptance kernel with no bounds, cast, or unreachable checks although the build had pinned zttp_proof_checker to ReleaseSafe since commit 0384765a."
  - "`@setRuntimeSafety(true)` as the first statement restored the checks only inside that function's own body; an unannotated callee and std.debug.assert stayed unchecked."
  - "A release probe that called only @panic passed in every optimize mode, so it proved nothing about runtime safety."
root_cause: wrong_api
resolution_type: code_fix
severity: high
framework_version: zig 0.16.0
related_components:
  - "proof-checker acceptance"
  - testing_framework
  - build
tags:
  - zig
  - build
  - runtime-safety
  - releasefast
  - proof-boundary
  - fail-open
  - gates
  - probes
retire_when: "A Zig release after 0.16.0 makes a dependency module's own .optimize govern runtime safety under a ReleaseFast root. Check without touching the repo: build the two-module probe from the Prevention section with root ReleaseFast and an unannotated ReleaseSafe dependency that indexes a 3-byte slice out of bounds. Zig 0.16.0 exits 0; if the newer Zig aborts with an index-out-of-bounds panic, the pin would work again and this learning retires, though the per-function setting stays harmless."
---

# A ReleaseSafe pin on a dependency module followed the root

## Problem

`packages/proof-checker` is the consumer-side acceptance kernel. It decodes certificate bytes that the consumer did not write, and its guards are what stand between those bytes and an out-of-range cast, an out-of-range slice, or an `unreachable`. Releases build with `zig build -Doptimize=ReleaseFast` (`.github/workflows/release.yml:129`). Under ReleaseFast a guard that is missing is undefined behavior rather than a panic, so the kernel is the one module in the tree where runtime safety has to stay on.

Commit 0384765a tried to keep it on by build mode. It computed `proof_checker_optimize = if (optimize == .Debug) .Debug else .ReleaseSafe` and passed that as the `.optimize` of the `zttp_proof_checker` dependency in all three places the dependency is declared (the root build, `packages/runtime/build.zig`, and `packages/tools/build.zig`). Its comment stated a measured cost: "about 30% per `check` call on the kernel fixture, roughly half a microsecond, paid once per start". The pin later moved with the rest of the root build into `build/Context.zig` and sat there at `build/Context.zig:163-174` (pre-fix tree, `ae26ba69^`).

The pin did nothing. On Zig 0.16.0 the safety checks compiled into a dependency module follow the root module's optimize mode, not the dependency's. With a ReleaseFast root, every `unreachable`, bounds check, and `@intCast` in the ReleaseSafe kernel compiled to nothing. The build graph accepted the declaration, the tests passed, two documents credited the pin, and the guarantee it named did not exist.

Fixed on main in commit ae26ba69. The two documents that credited the pin were corrected in 2e0e56e6.

## Symptoms

Nothing failed. There was no test that ran a kernel guard under a ReleaseFast root and required a panic, so the absence of the panic had no observer. The defect surfaced only when the claim was checked directly with a two-module probe, built with the installed `zig` 0.16.0 and with `@call(.never_inline, ...)` so the optimizer could not fold the call site.

The probe has a root module and a dependency module. The dependency holds three functions: one that runs `if (!ok) unreachable`, one that indexes a 3-byte slice at index 9, and one that calls `std.debug.assert(ok)`. The root passes `false` and index 9 derived from an argument. Measured, rerun while this document was written:

| root | dep | `unreachable` | `bytes[9]` on 3 bytes | `std.debug.assert(false)` |
|------|-----|---------------|-----------------------|---------------------------|
| ReleaseFast | ReleaseSafe | no panic, exit 0 | read a garbage byte (110 here, 111 in the session), exit 0 | no panic, exit 0 |
| ReleaseSafe | ReleaseFast | `panic: reached unreachable code` | `panic: index out of bounds: index 9, len 3` | `panic: reached unreachable code` |

The second row is the mirror image and is the whole finding: the dependency's own mode changed nothing, and the root's mode decided every check in both modules.

Two documents had already recorded the pin as a fact. `docs/plans/2026-09-24-proof-checker-rederive-review.md` gave the per-call timing (about 1.5 us under ReleaseFast against about 1.95 us under ReleaseSafe on the kernel fixture), and `docs/solutions/security-issues/a-trusted-edge-at-a-missing-node-was-accepted.md` closed its ReleaseFast paragraph with the pin. Both were true statements about a build declaration and false statements about the binary.

## What Didn't Work

**Reading the build file as proof.** The declaration was real. Three files set `.optimize` to ReleaseSafe for the kernel, the build graph deduplicated them into one module, and `std.Build.Module` does carry a per-module optimize mode. The language also reports a mode per module: the deprecation note on `std.debug.runtime_safety` at `/Users/srdjans/.zvm/0.16.0/lib/std/debug.zig:234-239` says the constant is deprecated "because it returns the optimization mode of the standard library, when the caller probably wants to use the optimization mode of their own module". A reader who knows that modules have modes concludes that a module's checks follow its mode. That inference is where the defect lived. What a module reports and what governs the checks emitted into it are two different questions, and only the second one matters. Only a probe answers it.

**Trusting the pin's comment.** The comment carried a real measurement: about 1.5 us per `check` call under ReleaseFast against about 1.95 us under ReleaseSafe. Per the session that made it, that benchmark was a standalone program compiled once per optimize mode, so the kernel sat under a ReleaseSafe root in one run and a ReleaseFast root in the other (session history). In that shape the mode does take effect, and the difference is a plausible measure of what runtime safety costs the kernel. It is not a measurement of the shipped configuration, where the kernel is a dependency under a ReleaseFast root. The benchmark answered "what does safety cost" and was read as also answering "does the pin deliver safety", which it cannot. A true number about the price made the unverified claim about the mechanism more convincing.

**Checking the wrong property of the pin.** The review that introduced the pin checked that the three declarations of the kernel dependency compute the same mode, so that they dedup into one module. It did not build a release binary and probe a guard. The same work probed every other gate it touched by injecting the fault the gate was meant to catch; the build-mode claim received no such probe, and later plan edits restated it as done (session history).

**A probe that panics in every mode.** The first release probe, written by Codex from the brief, called only `safety.check(false)`. `safety.check` is `if (!ok) @panic(...)` (`packages/proof-checker/src/safety.zig:3`), and `@panic` fires in every optimize mode. That probe passed with the mechanism present and would have passed with it absent, so it could not detect the failure it was written to detect. Review added the `index` case: an out-of-bounds read inside a function that begins with `@setRuntimeSafety(true)`, in a separate module imported by the ReleaseFast root, which is the shape of the shipped binaries.

**`std.debug.assert` as a guard.** `assert` is `if (!ok) unreachable` (`debug.zig:418-421`). Its body lives in the `std` module, so no setting in the calling function reaches it. In the probe's third column it stays silent under a ReleaseFast root even when the caller has enabled safety. The kernel had two `assert` sites; both were guards on kernel state.

## Solution

The fix keeps the safety setting where the compiler honors it: inside each function body. `@setRuntimeSafety(true)` as the first statement of a function enables the checks for that body under any root mode. Measured with the same two-module probe, root ReleaseFast and dependency ReleaseFast with the annotation in each function:

| case in the annotated dependency | result |
|----------------------------------|--------|
| `if (!ok) unreachable` | `panic: reached unreachable code` |
| `bytes[9]` on 3 bytes | `panic: index out of bounds: index 9, len 3` |
| `@intCast(u32 -> u8)` of 900 | `panic: integer does not fit in destination type` |
| annotated function calling an unannotated inner helper that indexes | read 0, no panic |
| `std.debug.assert(false)` | no panic |

The last two rows bound the mechanism. The setting covers the body it is written in and nothing that body calls. So the fix has four parts: the annotation in every kernel function, a `@panic`-based replacement for `assert`, an AST gate that keeps both true, and a release probe that shows the mechanism holds under a ReleaseFast root.

**Remove the pin.** Before, `build/Context.zig:163-174` at `ae26ba69^`:

```zig
// Consumer acceptance kernel. A release build keeps runtime safety in the
// kernel. Its guards are the only thing between certificate bytes and an
// out-of-range cast or slice, which ReleaseFast turns into undefined
// behavior and ReleaseSafe turns into a panic. The kernel runs once,
// before the pool exists, so that panic is a refusal to serve. Measured
// cost: about 30% per `check` call on the kernel fixture, roughly half a
// microsecond, paid once per start.
const proof_checker_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .Debug else .ReleaseSafe;
const proof_checker_dep = b.dependency("zttp_proof_checker", .{
    .target = target,
    .optimize = proof_checker_optimize,
});
```

After, `build/Context.zig:163-170`:

```zig
// Consumer acceptance kernel. Each function enables runtime safety with
// @setRuntimeSafety(true), enforced by test-kernel-safety. On Zig 0.16.0,
// a dependency module's optimize mode does not isolate runtime safety
// from a ReleaseFast root module.
const proof_checker_dep = b.dependency("zttp_proof_checker", .{
    .target = target,
    .optimize = optimize,
});
```

`packages/runtime/build.zig:45-50` and `packages/tools/build.zig:30-35` make the same change, each with the comment "Match the outer mode so this dependency dedups across build declarations. Each kernel function enables runtime safety; test-kernel-safety checks it."

**Annotate every kernel function and replace `assert`.** `packages/proof-checker/src/safety.zig:1-4` is the replacement:

```zig
pub fn check(ok: bool) void {
    @setRuntimeSafety(true);
    if (!ok) @panic("proof-checker invariant violated");
}
```

Before, in `checker.zig`:

```zig
fn pop(self: *RangeStack) void {
    std.debug.assert(self.len > 0);
    self.len -= 1;
}
```

After, `packages/proof-checker/src/checker.zig:116-120`:

```zig
fn pop(self: *RangeStack) void {
    @setRuntimeSafety(true);
    safety.check(self.len > 0);
    self.len -= 1;
}
```

The second `assert` site is now `safety.check(result.ready())` at `checker.zig:686`. Every non-test function in `packages/proof-checker/src` begins with the statement: 367 functions in 16 files, which is the count the gate prints at this tree. The package doc comment states the rule and its reason at `packages/proof-checker/src/root.zig:13-15`.

**Enforce it with the Zig AST.** `scripts/check-kernel-safety.sh:11-12` lists every kernel source file, tracked or untracked, and runs `scripts/kernel_safety_gate.zig` over the list. The gate parses each file with `std.zig.Ast` and refuses a file the parser cannot read (`scripts/kernel_safety_gate.zig:137-142`). It makes three checks:

- `checkFunctions` (`:41-63`) visits every `fn_decl` outside a `test_decl` and requires that the first statement of its body is exactly the four tokens `@setRuntimeSafety ( true )` (`isRuntimeSafetyStatement`, `:25-35`).
- `checkDebugAsserts` (`:65-89`) refuses the token sequence `std . debug . assert` outside a test, with the message "use safety.check".
- `checkSafetyDisabled` (`:91-110`) refuses any `@setRuntimeSafety` whose argument is not `true` outside a test (`:101`). Its comment says why: "A leading @setRuntimeSafety(true) is worth nothing if a later statement in the same body turns safety back off".

The gate asserts two floors before its pass means anything: at least 16 files and at least 300 non-test functions (`:3-4`, enforced at `:181-194`). A run that saw an empty file list or a tree where the parser skipped every body fails on the floor.

**Prove the mechanism under a ReleaseFast root.** `build/repo_gates.zig:29-60` wires the gate step `test-kernel-safety` and two probe runs, and `build.zig:45` attaches the step to `zig build test`. The probe module is compiled ReleaseFast (`repo_gates.zig:38`) and imports the real kernel (`:40`) and a stand-in module, also ReleaseFast (`:41-45`):

```zig
// build/kernel_safety_probe_dep.zig:6-9
pub fn indexAt(bytes: []const u8, index: usize) u8 {
    @setRuntimeSafety(true);
    return bytes[index];
}
```

`build/kernel_safety_release_probe.zig:15-23` derives the index from an argument so the optimizer cannot fold the bound, and calls through `@call(.never_inline, ...)`:

```zig
if (std.mem.eql(u8, mode, "index")) {
    const bytes = [_]u8{ 1, 2, 3 };
    // Derived from the argument so the optimizer cannot fold the bound.
    const index = mode.len + 4;
    const byte = @call(.never_inline, probe_dep.indexAt, .{ &bytes, index });
    std.debug.print("index probe read {d} without a panic\n", .{byte});
    return;
}
proof_checker.safety.check(false);
```

The `check` run requires stderr to contain "proof-checker invariant violated" and the process to end on `SIGABRT` (`repo_gates.zig:51-53`). The `index` run requires "index out of bounds" and `SIGABRT` (`:57-59`). A probe that prints its "without a panic" line and exits 0 fails both expectations.

**Adjust the two gates that read kernel bodies.** The invariant drift gate pins function bodies by text, so a new first statement in every body would have moved every pin. `normalizedBody` now strips the prefix `@setRuntimeSafety(true); ` when it is first (`packages/tools/src/invariant_drift_gate.zig:912-913`), and leaves it in place anywhere else, which its test checks. The residual-guard gate's Python extractor could not parse a `switch` body that starts with the statement, so `scripts/check-residual-guards.sh:45-49` now runs a Zig extractor, `scripts/residual_guard_extract.zig`, which also retires one of the legacy `python3` heredocs.

**Mutations, each run against the built gate.** Removing the annotation from `kernel_safety_probe_dep.zig`: the probe prints "index probe read 0 without a panic" and the gate fails on the stderr match and the exit term. Adding `@setRuntimeSafety(false)` to a kernel function: the gate fails at that line. Dropping the leading statement from a kernel function: the gate fails at that function. At this tree the gate passes with `kernel safety OK: checked 367 non-test function bodies in 16 files`, exit 0.

## Why This Works

A module's optimize mode is a property of the build graph. Whether the checks emitted into that module follow it is a property of the compiler, and on 0.16.0 they follow the root. `@setRuntimeSafety(true)` is different in kind: it is a statement the compiler resolves for the block it appears in, and the measured probe shows the compiler honors it under a ReleaseFast root for `unreachable`, bounds, and casts. Putting it at the top of the function body gives it the whole body as scope. The gate's requirement that it be the first statement is not a style rule; a later placement leaves the statements before it unchecked, and the drift gate's test for a "misplaced" statement records that a body with the statement in the middle is a different body.

The setting stops at the call boundary, and the fix is designed around that. `std.debug.assert` is the clearest case: its `unreachable` is in `std`, so no caller setting reaches it, which the probe's third column shows. `safety.check` replaces it with `@panic`, which the compiler never removes in any mode. The kernel's other calls into `std` stay unchecked, so the kernel checks lengths itself before it calls them; the `check` probe alone could never have shown that, because `@panic` is not a safety check.

The gate and the probe answer different questions. The gate answers "does every kernel function carry the setting", over the AST, with floors that make an empty or unparsed input a failure. The probe answers "does the setting do anything in the mode we ship", with an operation that exists only when safety is on. Either alone is porous: a gate over annotations says nothing about whether annotations work, and a probe over one function says nothing about the other 366. Together they cover the claim the pin had only asserted.

The stand-in module in the probe is deliberate. Calling into the real kernel with a bad index would need a certificate that reaches an unguarded site, and the point of the kernel is that no such site exists. The stand-in has the same shape as a kernel function, an annotated body in a separately compiled module under a ReleaseFast root, and holds the one unguarded index the probe needs.

## Prevention

**Never treat a per-module optimize mode as a safety boundary.** A `.optimize` on a dependency is a request to the build graph, and the compiler decides what it governs. On Zig 0.16.0 it does not govern runtime safety checks. A safety property that has to hold in one module of a ReleaseFast binary belongs in that module's source, as a per-function setting, where the compiler resolves it per block. If a later Zig changes this, the probe below will still be the evidence; the build file will not.

**Prove a claimed safety property with a probe in the shipped mode, using a check that only exists when safety is on.** Bounds, `@intCast`, and `unreachable` are such checks. `@panic` is not: it fires in every mode, so a probe built on it passes with and without the mechanism. Before the probe is trusted, run it once with the mechanism removed and confirm it fails; a probe that has never been seen failing has not been shown to detect anything. The first probe here had exactly that gap.

**Keep the two-module probe as the method.** It is two source files and one command per mode pair:

```
zig build-exe --name probe --dep dep -O ReleaseFast -Mroot=root.zig -O ReleaseSafe -Mdep=dep.zig
```

The `-O` before `-Mroot` applies to the root, the `-O` before `-Mdep` to the dependency. Derive the bad index from an argument, call through `@call(.never_inline, ...)`, and read the verdict from the exit status and the panic text, not from a grep over output that is empty on both a pass and a failed build.

**Enforce per-function annotations with an AST gate that has floors and refuses `false`.** Token-shaped rules over source need three things the kernel gate has: a floor on files and on functions so that an empty input fails, a parser-error refusal so that an unreadable file fails, and a rule against the inverse setting so that a later `@setRuntimeSafety(false)` cannot undo the leading one. Route the shell wrapper through `git ls-files --cached --others` so a new kernel file is inside the gate before it is staged.

**Know where the setting stops.** `@setRuntimeSafety(true)` covers its own block. It does not reach a callee in another module, including `std`, and it does not reach an unannotated helper in the same file. Guards on kernel state use `safety.check`, never `std.debug.assert`, and lengths are checked in kernel code before a `std` call consumes them. The gate's `assert` rule matches the spelled-out token sequence `std.debug.assert`; an alias such as `const assert = std.debug.assert;` would not match it. No such alias exists in the kernel at this tree, and adding one would need a gate change first.

**A measured number is evidence for what it measured.** The pin's "30%" was, by the best evidence available, a real cost of runtime safety in a standalone ReleaseSafe build. It said nothing about whether the shipped binary paid that cost. When a comment attaches a cost to a mechanism, the mechanism needs its own evidence in the shipped configuration. The cost of the per-function setting in the real ReleaseFast binary has not been measured.

**Correct the documents that credited the claim.** One solution document and one plan review had recorded the pin as fact. A retracted mechanism leaves those readers with a guarantee that never existed, so the correction commit is part of the fix, not a follow-up.

## Related

- [a-trusted-edge-at-a-missing-node-was-accepted.md](a-trusted-edge-at-a-missing-node-was-accepted.md): the kernel defect whose audit motivated the pin, and the first document that credited it.
- [../conventions/difference-is-not-the-claim-and-a-probe-must-compile.md](../conventions/difference-is-not-the-claim-and-a-probe-must-compile.md): the parent rule. A `@panic`-only probe asserts something weaker than "safety is on".
- [../conventions/a-gate-can-be-non-vacuous-and-still-porous.md](../conventions/a-gate-can-be-non-vacuous-and-still-porous.md): the mutation method used on the new gate and probe.
- [../conventions/a-gate-that-counts-nothing-still-reports-a-pass.md](../conventions/a-gate-that-counts-nothing-still-reports-a-pass.md): why the gate asserts floors on files and functions.
- `docs/plans/2026-09-24-proof-checker-rederive-review.md`: owner decision 1, now carrying a correction.

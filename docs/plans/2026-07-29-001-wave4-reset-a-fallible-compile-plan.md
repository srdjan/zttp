# Wave 4 Reset A: Fallible Compile Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the three infallible constructors that convert allocation failure into `unreachable`, so every compile path reports out-of-memory as an error instead of invoking undefined behavior.

**Architecture:** The parser already has correct fallible constructors (`initFallible`). Three thin wrappers named `init` call them and swallow the error with `catch unreachable`. This plan deletes the wrappers, renames each `initFallible` to `init`, and updates every call site to `try`. No new abstraction is introduced. The larger `CompileRequest` to `CompiledModule` session described in the reset plan's section 4.5 is deliberately NOT part of this plan; see "Scope boundary" below.

**Tech Stack:** Zig 0.16.0. No dependencies added.

## Scope boundary, read this before starting

The reset plan (`docs/plans/2026-07-28-001-reset-simplification-plan.md`, section 4.5) describes a full compile-session redesign: one `CompileRequest` to `CompiledModule` API, explicit Parsed/Resolved/Checked/Contracted/Lowered stages, one idempotent `deinit`, and an end to recreating type and checker state during contract extraction.

**This plan implements only the first, independently valuable slice of that: making construction fallible.** The reasons to split it:

- It is the part carrying an actual correctness defect. The rest is structural.
- It is mechanical and reviewable. The session redesign changes ownership across `packages/zts`, `packages/tools`, and `packages/pi`, and needs its own plan with a migration order.
- It leaves the tree working and better at every commit.

Do not start the session redesign inside this plan. When this plan is done, write a separate plan for it.

## Global Constraints

- Zig 0.16.0. Format with `zig fmt`; the gate runs `zig fmt --check build.zig packages/`.
- Work directly on local `main`. Commit each task separately. Never push.
- Prose in ASD-STE100 Simplified Technical English. No emojis. No em dashes.
- Never use `catch unreachable` for an operation that can genuinely fail.
- The full gate is `bash scripts/verify.sh`. It must exit 0 before any commit that changes Zig sources.
- **Read the recorded exit code, not a tail of the log.** Run it as
  `bash scripts/verify.sh > /tmp/v.txt 2>&1; echo "EXIT=$?"`. A completion notification
  reports the wrapper's status, not the script's. This caught two false "green" readings
  during the previous session.
- **Prefer explicit line ranges over name-and-brace heuristics** when deleting code with a script. Scripted deletion by pattern over-deleted five times in the previous session, including removing `Context.init` because its body mentioned a JIT field.
- After any change to engine internals, run `zig build bench-check` separately. The `test` step compiles the bench binaries but does not run them.

## Ground truth, measured 2026-07-29 at commit 7e76be3f

Three infallible wrappers exist. Each is a `catch unreachable` over a working fallible constructor:

| Wrapper | Line | Delegates to | Real failure source |
| --- | --- | --- | --- |
| `Parser.init` (the JS parser) | `packages/zts/src/parser/parse.zig:131-133` | `initFallible` at `:135` | `ScopeAnalyzer.initFallible` |
| `Parser.init` (legacy zruntime-compat wrapper) | `packages/zts/src/parser/root.zig:164-172` | `initFallible` at `:174` | allocations inside the wrapper |
| `ScopeAnalyzer.init` | `packages/zts/src/parser/scope.zig:150-152` | `initFallible` | its own allocations |

Call-site counts, measured by classifying each hit as inside or outside a `test "..."` block:

- **35 production call sites**, **181 inside test blocks**, 216 total for `Parser.init(`.
- Zig test blocks may return `!void`, so test sites migrate by adding `try` with no signature change.
- Two distinct symbols are involved and must not be confused:
  - `JsParser` is `parse.zig`'s `Parser`, re-exported at `packages/zts/src/parser/root.zig:64`. Called as `JsParser.init(allocator, source)`, 41 sites.
  - `parser.Parser` is the legacy wrapper struct at `packages/zts/src/parser/root.zig:142`. Called as `parser.Parser.init(allocator, source, strings, atoms)`, 3 production sites (`packages/zts/src/compiler.zig:30`, `:79`, plus tests in `parser/root.zig`).
  - Inside `parse.zig` itself, a bare `Parser.init(` means `JsParser`.

Production call sites by file (23 files, 35 sites):

```
 5  packages/tools/src/precompile.zig
 3  packages/zts/src/parser/root.zig
 3  packages/zts/src/path_generator.zig
 2  packages/zts/src/compiler.zig
 2  packages/zts/src/flow_checker.zig
 2  packages/zts/src/pipeline.zig
 2  packages/zts/src/strict_checker.zig
 1  each: packages/pi/src/tools/pi_forge_route.zig, pi_goal_check.zig,
        pi_repair_plan.zig, zts_expert_effects.zig, zts_expert_narrow.zig,
        packages/runtime/src/compile_benchmark.zig,
        packages/tools/src/precompile_buildtime.zig, property_expectations.zig,
        transpiler.zig,
        packages/zts/src/bool_checker.zig, contract_builder.zig,
        contract_json_parser.zig, handler_verifier.zig,
        packages/zts/src/modules/internal/module_graph.zig,
        packages/zts/src/system_linker.zig, type_checker.zig
```

`ScopeAnalyzer.init` has call sites only in `packages/zts/src/parser/codegen.zig` (3) and `scope.zig` (5).

## File Structure

No files are created or deleted. Modified files, and what changes in each:

- `packages/zts/src/parser/scope.zig` — delete the `init` wrapper, rename `initFallible` to `init`. Innermost dependency, so it goes first.
- `packages/zts/src/parser/parse.zig` — same for the JS parser; its `initFallible` already calls the scope constructor with `try`.
- `packages/zts/src/parser/root.zig` — same for the legacy wrapper.
- 23 caller files listed above — add `try`, and change the enclosing function's return type to an error union where it is not one already.

Task order follows the dependency order: scope, then parser, then the legacy wrapper, then callers grouped by package so each commit is reviewable on its own.

---

### Task 1: Make `ScopeAnalyzer` construction fallible

**Files:**
- Modify: `packages/zts/src/parser/scope.zig:150-152` (delete the wrapper), and the `initFallible` declaration below it (rename)
- Modify: `packages/zts/src/parser/codegen.zig` (3 call sites)
- Modify: `packages/zts/src/parser/scope.zig` (5 call sites, all in test blocks)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `ScopeAnalyzer.init(allocator: std.mem.Allocator) !ScopeAnalyzer`. There is no longer any infallible constructor. `parse.zig` Task 2 calls this with `try`.

- [x] **Step 1: Confirm the current shape before touching it**

Run:
```bash
sed -n '145,160p' packages/zts/src/parser/scope.zig
git grep -n 'ScopeAnalyzer.init' -- '*.zig'
```
Expected: an `init` at `:150` whose body is `return initFallible(allocator) catch unreachable;`, an `initFallible` below it, and 8 call sites total across `codegen.zig` and `scope.zig`.

If the line numbers differ, the file moved since this plan was written. Re-derive them with the same commands and continue; do not edit by line number without confirming.

- [x] **Step 2: Delete the wrapper and rename the fallible constructor**

Delete the whole `pub fn init(allocator: std.mem.Allocator) ScopeAnalyzer { ... }` block, including its doc comment if it has one. Then rename `initFallible` to `init`:

```zig
    pub fn init(allocator: std.mem.Allocator) !ScopeAnalyzer {
```

- [x] **Step 3: Update every call site to `try`**

For each of the 8 sites, add `try`:

```zig
    var scopes = try ScopeAnalyzer.init(allocator);
```

Where the enclosing function does not already return an error union, change its signature. For a test block, `test "name" { ... }` already permits `try`.

- [x] **Step 4: Build and run the engine tests**

Run:
```bash
zig build test-zts > /tmp/t.log 2>&1; echo "EXIT=$?"; grep -E 'error:|leaked' /tmp/t.log | head
```
Expected: `EXIT=0`, no output from the grep.

If you see `error: expected type 'ScopeAnalyzer', found '@typeInfo(...).error_union'`, a call site is missing its `try`. The message names the file and line.

- [x] **Step 5: Verify no infallible constructor remains in this file**

Run:
```bash
grep -n 'catch unreachable' packages/zts/src/parser/scope.zig
```
Expected: no output.

- [x] **Step 6: Format and commit**

```bash
zig fmt packages/zts/src/parser/scope.zig packages/zts/src/parser/codegen.zig
zig fmt --check build.zig packages/
git add packages/zts/src/parser/scope.zig packages/zts/src/parser/codegen.zig
git commit -m "refactor(parser): make ScopeAnalyzer construction fallible

ScopeAnalyzer.init wrapped initFallible in catch unreachable, so an
allocation failure during scope-analyzer construction was undefined behavior
rather than an error. The wrapper is deleted and initFallible is renamed to
init; all 8 call sites now use try.

Verified: zig build test-zts exit 0."
```

---

### Task 2: Make the JS parser construction fallible

**Files:**
- Modify: `packages/zts/src/parser/parse.zig:131-133` (delete the wrapper), `:135` (rename)
- Modify: call sites inside `packages/zts/src/parser/parse.zig` (86 sites, nearly all in test blocks)

**Interfaces:**
- Consumes: `ScopeAnalyzer.init(...) !ScopeAnalyzer` from Task 1. The body of the parser's fallible constructor already calls it with `try`, so no change is needed there.
- Produces: `Parser.init(allocator: std.mem.Allocator, source: []const u8) !Parser`, re-exported as `JsParser.init` from `packages/zts/src/parser/root.zig:64`. Tasks 3 through 6 call it with `try`.

- [x] **Step 1: Confirm the current shape**

Run:
```bash
sed -n '128,140p' packages/zts/src/parser/parse.zig
grep -c 'Parser\.init(' packages/zts/src/parser/parse.zig
```
Expected: `init` at `:131` delegating with `catch unreachable`, `initFallible` at `:135`, and 86 call sites in this file.

- [x] **Step 2: Delete the wrapper and rename**

Delete:

```zig
    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        return initFallible(allocator, source) catch unreachable;
    }
```

Rename the next declaration:

```zig
    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Parser {
```

- [x] **Step 3: Update this file's call sites**

Most are `var parser = Parser.init(allocator, source);` inside test blocks. Add `try`:

```zig
    var parser = try Parser.init(allocator, source);
```

Do this with an editor substitution scoped to this file, then read the diff before continuing:

```bash
git diff packages/zts/src/parser/parse.zig | grep -c '^+.*try Parser.init'
```
Expected: 86.

Do not use a repository-wide substitution. `Parser.init` also names the legacy wrapper in `root.zig`, which Task 3 handles separately with a different signature.

- [x] **Step 4: Build and run the engine tests**

Run:
```bash
zig build test-zts > /tmp/t.log 2>&1; echo "EXIT=$?"; grep -E 'error:|leaked' /tmp/t.log | head
```
Expected: `EXIT=0` and no grep output. Callers outside this file still fail to compile at this point only if they use `JsParser.init`; those are Tasks 4 to 6 and `test-zts` covers `packages/zts` only, so expect failures naming other `packages/zts` files and fix them as part of this task if they appear.

- [x] **Step 5: Commit**

```bash
zig fmt packages/zts/src/parser/parse.zig
zig fmt --check build.zig packages/
git add packages/zts/src/parser/parse.zig
git commit -m "refactor(parser): make JS parser construction fallible

Parser.init wrapped initFallible in catch unreachable, converting an
out-of-memory during parser construction into undefined behavior. The wrapper
is deleted and initFallible is renamed to init.

Verified: zig build test-zts exit 0."
```

---

### Task 3: Make the legacy parser wrapper fallible

**Files:**
- Modify: `packages/zts/src/parser/root.zig:164-172` (delete the wrapper), `:174` (rename)
- Modify: `packages/zts/src/compiler.zig:30`, `:79`
- Modify: test call sites inside `packages/zts/src/parser/root.zig` (12 total sites in this file)

**Interfaces:**
- Consumes: nothing from Tasks 1 and 2; this struct has its own constructor.
- Produces: `parser.Parser.init(allocator, source, strings, atoms) !Parser`.

- [x] **Step 1: Confirm the current shape**

Run:
```bash
sed -n '160,185p' packages/zts/src/parser/root.zig
git grep -n 'parser\.Parser\.init(' -- '*.zig'
```
Expected: the four-argument `init` at `:164` delegating with `catch unreachable`, and two production call sites in `packages/zts/src/compiler.zig`.

- [x] **Step 2: Delete the wrapper and rename**

Delete the `pub fn init(...) Parser { return initFallible(...) catch unreachable; }` block and rename the declaration below it:

```zig
    pub fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        strings: *string.StringTable,
        atoms: ?*context.AtomTable,
    ) !Parser {
```

- [x] **Step 3: Update the two compiler call sites**

In `packages/zts/src/compiler.zig`, both sites are inside functions that already return an error union (`compile` and `compileWithOptions` both return `!*bytecode.FunctionBytecode`):

```zig
    var p = try parser.Parser.init(allocator, source, &strings, null);
```

- [x] **Step 4: Update this file's test call sites**

Add `try` to each remaining `Parser.init(` in `packages/zts/src/parser/root.zig`.

- [x] **Step 5: Build and test**

Run:
```bash
zig build test-zts > /tmp/t.log 2>&1; echo "EXIT=$?"; grep -E 'error:|leaked' /tmp/t.log | head
```
Expected: `EXIT=0`, no grep output.

- [x] **Step 6: Verify the parser package is free of the pattern**

Run:
```bash
grep -rn 'catch unreachable' packages/zts/src/parser/
```
Expected: only `parse.zig:3554` (a `bufPrint` into a fixed stack buffer that cannot fail) and the two `_ = result catch unreachable;` lines in test blocks around `:5244` and `:5257`. Those are honest and stay. If anything else appears, it is a wrapper this plan missed; handle it the same way.

- [x] **Step 7: Commit**

```bash
zig fmt packages/zts/src/parser/root.zig packages/zts/src/compiler.zig
zig fmt --check build.zig packages/
git add packages/zts/src/parser/root.zig packages/zts/src/compiler.zig
git commit -m "refactor(parser): make the legacy parser wrapper fallible

The zruntime-compatibility Parser wrapper converted allocation failure into
undefined behavior through catch unreachable. Deleted; initFallible is renamed
to init and both compiler.zig call sites use try.

Verified: zig build test-zts exit 0."
```

---

### Task 4: Migrate the remaining `packages/zts` callers

**Files:**
- Modify: `packages/zts/src/path_generator.zig` (3), `flow_checker.zig` (2), `pipeline.zig` (2), `strict_checker.zig` (2), `bool_checker.zig` (1), `contract_builder.zig` (1), `contract_json_parser.zig` (1), `handler_verifier.zig` (1), `system_linker.zig` (1), `type_checker.zig` (1), `modules/internal/module_graph.zig` (1), `interpreter/trace.zig` (1)

**Interfaces:**
- Consumes: `JsParser.init(...) !Parser` from Task 2.
- Produces: nothing new. This task only propagates `try`.

- [x] **Step 1: List the sites that still fail to compile**

Run:
```bash
zig build test-zts > /tmp/t.log 2>&1; echo "EXIT=$?"
grep -E '^packages.*error:' /tmp/t.log | sort -u
```
The compiler names every remaining site. Work the list top to bottom.

- [x] **Step 2: Add `try` at each site, and propagate the error type outward where needed**

The usual shape:

```zig
    var p = try JsParser.init(allocator, source);
    defer p.deinit();
```

Where the enclosing function returns a plain type, change it to an error union. For example a helper declared `fn buildIr(allocator: std.mem.Allocator, src: []const u8) Ir` becomes `fn buildIr(allocator: std.mem.Allocator, src: []const u8) !Ir`, and its own callers gain `try`. Follow the compiler's error messages outward until it is quiet.

Do not silence a site with `catch unreachable` or `catch undefined`. That reintroduces exactly the defect this plan removes. If a site genuinely cannot propagate an error, stop and record why in the plan's Open Questions section rather than working around it.

- [x] **Step 3: Build and test until clean**

Run:
```bash
zig build test-zts > /tmp/t.log 2>&1; echo "EXIT=$?"; grep -E 'error:|leaked' /tmp/t.log | head
```
Expected: `EXIT=0`, no grep output.

- [x] **Step 4: Commit**

```bash
zig fmt packages/
zig fmt --check build.zig packages/
git add packages/zts
git commit -m "refactor(zts): propagate parser construction errors through analyzers

Adds try at the remaining packages/zts call sites and widens the enclosing
signatures to error unions where needed, so an out-of-memory during parser
construction now surfaces as an error instead of being unreachable.

Verified: zig build test-zts exit 0."
```

---

### Task 5: Migrate `packages/tools` and `packages/runtime` callers

**Files:**
- Modify: `packages/tools/src/precompile.zig` (5), `precompile_buildtime.zig` (1), `property_expectations.zig` (1), `transpiler.zig` (1)
- Modify: `packages/runtime/src/compile_benchmark.zig` (1)

**Interfaces:**
- Consumes: `JsParser.init(...) !Parser` from Task 2.
- Produces: nothing new.

- [x] **Step 1: Build the whole tree to surface the sites**

Run:
```bash
zig build > /tmp/b.log 2>&1; echo "EXIT=$?"
grep -E '^packages.*error:' /tmp/b.log | sort -u
```

- [x] **Step 2: Add `try` at each site and widen signatures as needed**

Same shape as Task 4. `precompile.zig`'s sites are inside functions that already return error unions, so most need only `try`:

```zig
    var js_parser = try zts.parser.JsParser.init(allocator, source_to_parse);
```

- [x] **Step 3: Build clean, then run the suites that cover these packages**

Run:
```bash
zig build > /tmp/b.log 2>&1; echo "BUILD=$?"
zig build test-precompile > /tmp/p.log 2>&1; echo "PRECOMPILE=$?"
zig build test-zruntime > /tmp/r.log 2>&1; echo "ZRUNTIME=$?"
```
Expected: all three `=0`.

- [x] **Step 4: Confirm the benchmark binaries still compile**

Run:
```bash
zig build bench-check > /tmp/bc.log 2>&1; echo "EXIT=$?"; grep -E 'ok:|regress|error:' /tmp/bc.log | tail -2
```
Expected: `EXIT=0` and an `ok:` line. If a benchmark regresses more than 8 percent, re-run once before believing it; `intArithmetic` has a measured run-to-run spread near 10 percent on a loaded host, and a false failure from it cost time in the previous session.

- [x] **Step 5: Commit**

```bash
zig fmt packages/
zig fmt --check build.zig packages/
git add packages/tools packages/runtime
git commit -m "refactor(tools,runtime): propagate parser construction errors

Adds try at the precompile, transpiler, property-expectations, and
compile-benchmark call sites.

Verified: zig build test-precompile and test-zruntime exit 0, bench-check ok."
```

---

### Task 6: Migrate `packages/pi` callers and close out

**Files:**
- Modify: `packages/pi/src/tools/pi_forge_route.zig` (1), `pi_goal_check.zig` (1), `pi_repair_plan.zig` (1), `zts_expert_effects.zig` (1), `zts_expert_narrow.zig` (1)

**Interfaces:**
- Consumes: `JsParser.init(...) !Parser` from Task 2.
- Produces: nothing new. This is the last caller group.

- [x] **Step 1: Build and list remaining sites**

Run:
```bash
zig build > /tmp/b.log 2>&1; echo "EXIT=$?"; grep -E '^packages/pi.*error:' /tmp/b.log | sort -u
```

- [x] **Step 2: Add `try` at each site**

These are pi tools whose `execute` entry points already return error unions, so `try` should be sufficient. Confirm rather than assume: if a signature needs widening, the compiler says so.

- [x] **Step 3: Verify no infallible constructor survives anywhere**

Run:
```bash
git grep -n 'initFallible' -- '*.zig'
```
Expected: no output. Every `initFallible` has been renamed to `init`.

Run:
```bash
git grep -n 'init(.*) Parser {\|init(.*) ScopeAnalyzer {' -- '*.zig'
```
Expected: no output. Every parser and scope constructor now returns an error union.

- [x] **Step 4: Run the full gate**

Run:
```bash
bash scripts/verify.sh > /tmp/v.txt 2>&1; echo "EXIT=$?"; tail -3 /tmp/v.txt
```
Expected: `EXIT=0` and the "all CI test-job steps passed" banner. Read the `EXIT=` line, not just the tail.

- [x] **Step 5: Prove the change did something, with a failure-injection test**

This is the acceptance criterion from the reset plan: construction failure must surface as an error. Add this test to `packages/zts/src/parser/parse.zig`, at the end of the file:

```zig
test "parser construction reports allocation failure instead of panicking" {
    // A failing allocator makes ScopeAnalyzer construction fail, which the
    // parser must propagate. Before this was fallible, the same condition
    // reached `catch unreachable` and was undefined behavior.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Parser.init(failing.allocator(), "const x = 1;"));
}
```

Run:
```bash
zig build test-zts -- --test-filter "reports allocation failure" > /tmp/t.log 2>&1; echo "EXIT=$?"; tail -3 /tmp/t.log
```
Expected: `EXIT=0`.

If the test fails with "expected error.OutOfMemory, found ...", the first allocation in the constructor is not the one that fails; raise `fail_index` until it is the constructor's allocation, and leave the working index in the committed test.

- [x] **Step 6: Update the reset plan's section 4.5**

In `docs/plans/2026-07-28-001-reset-simplification-plan.md`, in the "Compilation ownership, verified" subsection, append:

```markdown
**Status, 2026-07-29:** The infallible constructors are removed. `ScopeAnalyzer.init`,
the JS `Parser.init`, and the legacy wrapper's `init` all return error unions, and every
call site propagates. A failure-injection test in `parse.zig` pins the behavior. The
remaining part of this finding, the `CompileRequest` to `CompiledModule` session with
explicit stages and one idempotent deinit, is NOT done and needs its own plan.
```

- [x] **Step 7: Commit**

```bash
zig fmt packages/
zig fmt --check build.zig packages/
git add packages/pi packages/zts docs/plans
git commit -m "refactor(pi): propagate parser construction errors, close reset A

Last caller group. Adds a failure-injection test pinning that parser
construction reports OutOfMemory rather than reaching unreachable, and records
the status in the reset plan.

No initFallible remains: every parser and scope constructor returns an error
union.

Verified: scripts/verify.sh exit 0, zig fmt clean."
```

---

## Acceptance criteria for the whole plan

1. `git grep -n 'initFallible' -- '*.zig'` returns nothing.
2. `git grep -n 'catch unreachable' -- 'packages/zts/src/parser/'` returns only the honest `bufPrint` site and the two test-block lines described in Task 3 Step 6.
3. The failure-injection test from Task 6 passes.
4. `bash scripts/verify.sh` exits 0.
5. `zig build bench-check` exits 0.

## Open questions to record, not to solve here

- Whether `Parser` should keep two entry points at all. `parser.Parser` at `root.zig:142` is documented as a compatibility wrapper for `zruntime.zig`, and `JsParser` is the real parser. Collapsing them belongs to the session redesign, not here.
- `IRStore.initCapacity(allocator, source.len)` at `parse.zig:136` is called without `try` inside the fallible constructor. Check whether it can fail; if it can, it is a second silent failure path and deserves its own task. This plan does not change it.

## What comes after this plan

Wave 4 has three more ownership resets, each needing its own plan:

- **Reset B, ModuleFacts and the canonical codec.** One immutable facts index built once from parsed and checked source, replacing the repeated mutable scans in `contract_builder.zig`, and replacing the runtime's second hand-written contract reader (`packages/runtime/src/contract_runtime.zig`, 1,818 lines) with the canonical codec plus a runtime projection. Acceptance is byte-identical contract fixtures, which the goldens added in `packages/tools/tests/fixtures/contract/` already pin.
- **Reset C, HandlerInstance.** Make the pool own a `HandlerInstance` that owns the engine runtime, installed builtins, loaded handler, and reset lifecycle, removing the runtime-to-pool back-imports.
- **Reset D, InvocationContext and ExecutionSpec.** Replace the ambient threadlocals (`zruntime.zig:137` `current_runtime`, `:143` `last_fault_location`, `:155` `aot_override`, `:2289` `active_ws_connection`, and `http.zig:23` `call_function_callback`) with an explicit per-invocation context, and introduce a data-only `ExecutionSpec` so durable scheduling stops depending on the full `ServerConfig`.

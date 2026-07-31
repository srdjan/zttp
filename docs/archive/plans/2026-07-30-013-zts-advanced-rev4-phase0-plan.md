# Phase 0: truth, ternary, and the advisory channel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Admit pure `?:` with the spec's join rule, add the `advisory` severity and an idiom registry, re-badge existing canonicalize rewrites under idiom IDs, and stop over-claiming totality and exhaustiveness — the smallest coherent slice of `zts-advanced-1` revision 4.

**Architecture:** All changes ride existing machinery: the strict checker's diagnostic walk (`strict_checker.zig`), the rule registry (`rule_registry.zig`), the type checker's expression typing (`type_checker.zig` with `type_pool.zig` assignability as the D1-interim relation), the canonicalize fixed-point loop (`packages/tools/src/canonicalize.zig`), and the path generator's envelope flags (`path_generator.zig`). Zero kernel, GC, interpreter, or value-representation changes. The semantics registry already holds the ternary node rule, so `spec-check` stays green by construction.

**Tech Stack:** Zig 0.16.0, `zig build test-zts` / `zig build test`, `bash scripts/verify.sh`, `zig fmt`.

## Global Constraints

- Spec source of truth: `docs/zts-formal-spec-northstar-advanced.md` revision 4. Cited rules: pure `?:` and no-nesting (spec 5.4, lines ~924-944), branch-selection decidable rule (5.4), join steps 1-5 (5.4, lines ~946-963), closed severity set and success rule (4.8, lines ~604-614), idiom table and advisory contract (4.2.1, lines ~328-397), honesty items (section 3 gaps 10-11, 13.1 labeling discipline).
- Interim relations, marked in code: assignability = `type_pool.zig` `isAssignableTo` (`// D1-interim`); purity = syntactic-pure expression class defined in Task 3 (`// D2-interim`).
- Every task: `zig fmt` on touched files before commit; tests live in `test "..."` blocks next to code; run the named test step before and after; commit per task; never push.
- No behavior change outside the named surfaces: `zttp check` exit semantics for `error` diagnostics unchanged; `advisory` MUST NOT affect exit codes or success anywhere.
- End state gate: `bash scripts/verify.sh` green, `zig build test` green, `bash scripts/test-examples.sh` green.

---

### Task 1: `advisory` severity in the strict checker and JSON surface

**Files:**
- Modify: `packages/zts/src/strict_checker.zig:30-40` (Severity enum)
- Modify: `packages/tools/src/json_diagnostics.zig` (severity passthrough — confirm sites near lines 280, 317-318, 518)
- Test: same files, `test "..."` blocks

**Interfaces:**
- Consumes: nothing new.
- Produces: `Severity = enum { err, warning, advisory }` with `label()` returning `"advisory"`; every existing exit-code / success decision keyed on `.err` only. Task 5 and Task 6 emit `.advisory` diagnostics; Task 2 exposes the severity set.

- [x] **Step 1: Write the failing test** in `strict_checker.zig` next to the Severity enum:

```zig
test "advisory severity label" {
    try std.testing.expectEqualStrings("advisory", Severity.advisory.label());
}
```

- [x] **Step 2: Run it, expect compile failure** (`advisory` not a member):

Run: `zig build test-zts -- --test-filter "advisory severity label"`
Expected: compile error `enum 'Severity' has no member named 'advisory'`

- [x] **Step 3: Extend the enum**

```zig
pub const Severity = enum {
    err,
    warning,
    advisory,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .advisory => "advisory",
        };
    }
};
```

- [x] **Step 4: Audit every switch and comparison on `Severity`.** Run `grep -n "Severity\|severity ==\|\.err" packages/zts/src/strict_checker.zig packages/tools/src/json_diagnostics.zig packages/tools/src/zts_cli.zig` and confirm: (a) exhaustive switches now handle `.advisory` (the compiler forces this — fix each site so advisory routes like warning for display and like nothing for failure); (b) any "has errors" / exit-code decision tests `== .err` specifically, not "not warning". Fix any site that would let advisory flip an exit code.

- [x] **Step 5: Add the success-isolation test** in `strict_checker.zig`:

```zig
test "advisory diagnostics do not count as errors" {
    var checker = try checkSource("function handler(req) { return Response.json({ok: true}); }");
    defer checker.deinit();
    // Inject an advisory directly; no rule emits one until Task 5.
    checker.addDiagnostic(.{
        .severity = .advisory,
        .kind = .canonical_redundant_bool_compare,
        .node = 0,
        .message = "test advisory",
        .help = "none",
        .repair_intent = null,
    });
    var err_count: usize = 0;
    for (checker.getDiagnostics()) |diag| {
        if (diag.severity == .err) err_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), err_count);
}
```

(Adjust the `addDiagnostic` payload to the struct's actual fields — read the `Diagnostic` struct at the top of `strict_checker.zig` first; the test's assertion is the deliverable.)

- [x] **Step 6: Run the two tests, expect PASS**

Run: `zig build test-zts -- --test-filter "advisory"`
Expected: PASS (2 tests)

- [x] **Step 7: Commit**

```bash
zig fmt packages/zts/src/strict_checker.zig packages/tools/src/json_diagnostics.zig
git add -A && git commit -m "feat(checker): add advisory severity that never affects success"
```

### Task 2: idiom registry seed

**Files:**
- Create: `packages/zts/src/idiom_registry.zig`
- Modify: `packages/tools/src/zts_cli.zig` (wire `describe-rule --json` / `meta --json` to include the idiom list — locate the JSON emission for rules first)
- Test: in `idiom_registry.zig`

**Interfaces:**
- Consumes: nothing.
- Produces: `pub const IdiomEntry = struct { id: []const u8, operation: []const u8, idiomatic: []const u8, superseded: []const u8, precondition: []const u8, rewrite_rule: ?[]const u8 };` and `pub const entries: []const IdiomEntry`. Task 5 references entries by `id`. IDs are stable strings `idiom.<operation-slug>` (for example `idiom.absence-default`).

- [x] **Step 1: Write the failing test**

```zig
const std = @import("std");

test "idiom registry has unique stable ids" {
    for (entries, 0..) |entry, i| {
        try std.testing.expect(std.mem.startsWith(u8, entry.id, "idiom."));
        for (entries[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, entry.id, other.id));
        }
    }
    try std.testing.expect(entries.len >= 8);
}
```

- [x] **Step 2: Run, expect failure** (file missing / entries undefined). Add the new file to the test root the same way sibling registries are included — check how `rule_registry.zig` is imported in `packages/zts/src/root.zig` and mirror it.

- [x] **Step 3: Implement the seed table** — the ~10 rows from spec 4.2.1 that need no new language, transcribed verbatim from the table (idiomatic and superseded columns as the spec spells them): `idiom.absence-default`, `idiom.absent-member-read`, `idiom.number-in-text`, `idiom.scalar-to-text`, `idiom.redundant-template`, `idiom.string-concatenation`, `idiom.array-concatenation`, `idiom.membership-test`, `idiom.existence-test`, `idiom.field-read`, `idiom.multi-field-read`, `idiom.element-iteration`. `rewrite_rule` is null except where Task 5 wires an existing canonicalize rewrite.

- [x] **Step 4: Run test, expect PASS.** `zig build test-zts -- --test-filter "idiom registry"`

- [x] **Step 5: Expose in JSON.** In `zts_cli.zig`, find where `describe-rule --json` serializes the rule list and add a sibling `"idioms": [...]` array (id, operation, idiomatic, superseded, precondition, rewrite_rule). Add a CLI test if the file has a harness for JSON output; otherwise verify by hand:

Run: `zig build && ./zig-out/bin/zts describe-rule --json | python3 -c "import json,sys; d=json.load(sys.stdin); assert any(k.startswith('idiom.') for k in [e['id'] for e in d['idioms']]); print('ok')"`
Expected: `ok`

**Deviation, 2026-07-31.** The idioms went behind a new `--idioms` flag, not into
the no-arg `describe-rule --json` output. That output is a bare JSON array of
rules (`describe_rule.zig:85-90`), duplicated byte-for-byte by
`packages/pi/src/tools/zts_expert_describe_rule.zig` and published in
`docs/internals/zts-expert-contract.md`, so adding a sibling key meant turning
the array into an object and breaking both. An idiom also has no code,
category, or severity, so it does not fit the rule shape. Spec 5 names the
`meta` payload as the idiom table's home; moving it there is Phase 1 protocol
work, and `--idioms` is the additive surface until then. The verification
command becomes:

`./zig-out/bin/zts describe-rule --idioms --json | python3 -c "import json,sys; d=json.load(sys.stdin); assert all(e['id'].startswith('idiom.') for e in d['idioms']); print('ok', len(d['idioms']))"`
Expected: `ok 12`

Also touched, beyond the file list above: `scripts/module-boundary.allow` needs
a `tools idiom_registry` row for `describe_rule.zig` to name the new internal
module, and `docs/cli.md` documents the flag.

- [x] **Step 6: Commit**

```bash
zig fmt packages/zts/src/idiom_registry.zig packages/tools/src/zts_cli.zig
git add -A && git commit -m "feat(registry): seed the idiom registry and expose it in describe-rule"
```

### Task 3: admit pure `?:` in the strict checker

**Files:**
- Modify: `packages/zts/src/strict_checker.zig:53` (DiagnosticKind), `:69` (isCanonicalProfile), `:332-344` (the `.ternary` arm of `walkExpr`), tests at `:1515-1519`
- Modify: `packages/zts/src/rule_registry.zig:287-294` (replace the ZTS612 entry)

**Interfaces:**
- Consumes: `Severity.advisory` from Task 1 is NOT used here — impure and chained ternaries are hard errors per spec 5.4.
- Produces: `DiagnosticKind.canonical_ternary_impure` and `DiagnosticKind.canonical_ternary_chain` replacing `canonical_ternary`; a file-local `fn isPureExpr(self: *StrictChecker, node: NodeIndex) bool` used by Task 3 only (D2-interim). Task 4 relies on ternaries reaching the type checker unrejected.

- [x] **Step 1: Replace the three ternary tests** at `strict_checker.zig:1515` with failing ones:

```zig
test "pure ternary is admitted" {
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? 200 : 500; return Response.json({x}); }");
    defer checker.deinit();
    for (checker.getDiagnostics()) |diag| {
        try std.testing.expect(diag.kind != .canonical_ternary_impure);
        try std.testing.expect(diag.kind != .canonical_ternary_chain);
    }
}

test "ternary with a call arm fires impure diagnostic" {
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? load(req) : 500; return Response.json({x}); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_ternary_impure);
}

test "chained ternary fires chain diagnostic" {
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? 1 : req.method === 'POST' ? 2 : 3; return Response.json({x}); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_ternary_chain);
}
```

- [x] **Step 2: Run, expect compile failure** (kinds missing).

Run: `zig build test-zts -- --test-filter "ternary"`

- [x] **Step 3: Implement.** (a) In `DiagnosticKind`, replace `canonical_ternary` with `canonical_ternary_impure` and `canonical_ternary_chain`; update `isCanonicalProfile` to list both. (b) Define the D2-interim purity predicate:

```zig
// D2-interim: syntactic purity for ?: arms until the effects-and-purity
// design doc defines the real predicate. Pure = literals, identifiers,
// member reads, unary/binary operators, template literals over pure parts,
// array/record literals over pure parts. Any call, method call, or
// assignment is impure.
fn isPureExpr(self: *StrictChecker, node: NodeIndex) bool {
    if (node == null_node) return true;
    const tag = self.ir_view.getTag(node) orelse return true;
    return switch (tag) {
        .call, .method_call, .assignment => false,
        .ternary => blk: {
            const t = self.ir_view.getTernary(node) orelse break :blk true;
            break :blk self.isPureExpr(t.condition) and
                self.isPureExpr(t.then_branch) and self.isPureExpr(t.else_branch);
        },
        .binary_op => blk: {
            const bin = self.ir_view.getBinary(node) orelse break :blk true;
            break :blk self.isPureExpr(bin.left) and self.isPureExpr(bin.right);
        },
        .unary_op => blk: {
            const un = self.ir_view.getUnary(node) orelse break :blk true;
            break :blk self.isPureExpr(un.operand);
        },
        else => true,
    };
}
```

Extend the composite cases (array/record/template/member) to recurse over children using the same `ir_view` accessors the surrounding walk uses — copy the child-iteration shapes from `walkExpr`. (c) Rewrite the `.ternary` arm: fire `canonical_ternary_chain` when either branch's tag is `.ternary` (spec: "parenthesized or not" — parens do not create nodes, so the tag test is exact); else fire `canonical_ternary_impure` when `!isPureExpr(then) or !isPureExpr(else)`; else no diagnostic. Always walk children afterward, as the current code does.

- [x] **Step 4: Update `rule_registry.zig`** — replace the ZTS612 entry with two entries (keep ZTS612 for impure, mint the next free code for chain — check the highest existing ZTS6xx first):

```zig
.{
    .kind = .canonical_ternary_impure,
    .code = "ZTS612",
    .description = "A ?: arm must be a pure value; effectful selection uses match or if.",
    .example = "const x = ready ? load() : fallback;",
    .help = "Bind the effectful call first, or use `match` over the condition for an effectful two-way choice.",
    .repair = .replace_ternary_with_if,
},
.{
    .kind = .canonical_ternary_chain,
    .code = "ZTS6xx", // next free code
    .description = "A conditional expression may not appear as an arm of another conditional expression.",
    .example = "const x = a ? 1 : b ? 2 : 3;",
    .help = "Use match over one scrutinee, or an if/else chain feeding a named function.",
    .repair = .replace_ternary_with_if,
},
```

- [x] **Step 5: Sweep for stale references.** `grep -rn "canonical_ternary\b" packages/` — fix every remaining site (canonicalize repair plans, docs, tests) to the new kinds.

**What the sweep actually found, 2026-07-31**, beyond the plan's file list:

1. `canonicalize.zig:923` dispatches the ternary rewrite on the literal string
   `"ZTS612"`. ZTS621 needed adding to that condition or chained ternaries
   would report with a repair that never applied — `normalize` returned
   `iterations: 0, fullyCanonical: false` with the chain as residual.
2. Six `canonicalize.zig` tests drove the rewriter with a *pure unchained*
   ternary, which this task admits, so the rewriter stopped running. Five were
   re-pointed at an impure or chained vehicle, keeping the machinery each one
   guards (condition parenthesization, the `=>` boundary, string-literal
   `?`/`:` safety, object-literal in-place splicing).
3. The nested-ternary test changed meaning, not just fixture. `a ? x : b ? y : z`
   now unchains to `match (!!(a)) { when true: x, default: b ? y : z }` and
   stops: only the outer conditional was a defect, and the freed inner one is
   idiomatic. The old test asserted both became `match` and that no `?`
   survived. Renamed to "unchains ... and stops".
4. Adding a rule shifts the policy hash, so `policy-hash.txt` and the five
   expert goldens under `packages/tools/tests/fixtures/expert/` regenerate via
   `bash scripts/update-expert-goldens.sh`. The golden diff is confined to
   `policy_hash`, `rule_count` 67 to 68, and `categories.verifier` 45 to 46.

- [x] **Step 6: Run, expect PASS**, then run the full checker suite:

Run: `zig build test-zts -- --test-filter "ternary"` then `zig build test-zts`
Expected: PASS; no other test regressions.

- [x] **Step 7: Commit**

```bash
zig fmt packages/zts/src/strict_checker.zig packages/zts/src/rule_registry.zig
git add -A && git commit -m "feat(checker): admit pure ternary, reject impure and chained forms"
```

### Task 4: ternary join in the type checker

**Files:**
- Modify: `packages/zts/src/type_checker.zig` (the `.ternary` typing sites — read the three arms at lines ~466, ~514, ~1198 first and find where an expression's type is computed; the walk-only arms stay walks)
- Test: `type_checker.zig` test section (existing distinct-type tests near line 2792 show the harness pattern)

**Interfaces:**
- Consumes: `type_pool.zig:1058` `isAssignableTo` as the D1-interim assignability.
- Produces: ternary expressions get type `join(then, else)` per spec 5.4 steps 1-5; step 3 = when mutually assignable use the `whenTrue` type; step 5 = the pool's existing union constructor. Later phases replace the relation, not the join shape.

- [x] **Step 1: Write failing tests** (mirror the harness used by the distinct-type tests — read them first, reuse their setup helper):

```zig
test "ternary join: identical types" {
    // const x = cond ? 1 : 2;  -> number
    // assert inferred type of x is number
}

// CORRECTION, 2026-07-31: `cond ? 1 : 2` is `1 | 2`, not `number`. The checker
// gives an integer literal its own literal type, so `1` and `2` are distinct
// and neither is assignable to the other: step 5 applies, not step 2, and
// widening to `number` would discard information the checker holds. Both
// outcomes are now pinned - step 2 by a test over two `string` bindings, step 5
// by this literal case.

test "ternary join: literal widens into receiving branch type" {
    // const s = cond ? "a" : someString;  -> string (step 4: literal assignable to string)
}

test "ternary join: disjoint types form a union" {
    // const u = cond ? 1 : "a";  -> number | string (step 5)
}
```

Write these as real tests against the checker harness: each parses a snippet, runs the type checker, and asserts the pool type of the binding. Copy the exact setup from the nearest existing inference test; the three snippets and three expected types above are the deliverable.

- [x] **Step 2: Run, expect FAIL** (current behavior: whatever the checker does today for ternary — likely `unknown` or the then-branch type).

- [x] **Step 3: Implement `joinTypes`** in `type_checker.zig`:

```zig
// Spec 5.4 join, steps 1-5. D1-interim: mutual assignability uses
// type_pool.isAssignableTo in both directions.
fn joinTypes(self: *TypeChecker, when_true: TypeIndex, when_false: TypeIndex) TypeIndex {
    // 1. never-removal
    if (self.pool.isNever(when_true) and self.pool.isNever(when_false)) return when_true;
    if (self.pool.isNever(when_true)) return when_false;
    if (self.pool.isNever(when_false)) return when_true;
    // 2. syntactic identity
    if (when_true == when_false) return when_true;
    const t_to_f = self.pool.isAssignableTo(when_true, when_false);
    const f_to_t = self.pool.isAssignableTo(when_false, when_true);
    // 3. mutually assignable: the whenTrue branch wins
    if (t_to_f and f_to_t) return when_true;
    // 4. one-way assignable: the receiving type wins
    if (t_to_f) return when_false;
    if (f_to_t) return when_true;
    // 5. normalized union
    return self.pool.makeUnion(&.{ when_true, when_false });
}
```

Adjust names to the pool's real API (`isNever`, `makeUnion` — grep `type_pool.zig` for the union constructor and never checks; if `isNever` does not exist, compare against the pool's never index constant the way `null_type_idx` is used). Wire it into the expression-typing `.ternary` arm: type the condition (assert boolean where the checker enforces operand types), type both branches, return `joinTypes`.

- [x] **Step 4: Run tests, expect PASS.** `zig build test-zts -- --test-filter "ternary join"`

- [x] **Step 5: Full suite.** `zig build test-zts` — fix regressions (most likely: code paths that assumed ternary was rejected upstream).

- [x] **Step 6: Commit**

```bash
zig fmt packages/zts/src/type_checker.zig
git add -A && git commit -m "feat(types): ternary result type via the spec join rule (D1-interim assignability)"
```

### Task 5: re-badge canonicalize rewrites with idiom IDs

**Files:**
- Modify: `packages/tools/src/canonicalize.zig` (locate the rewrite catalog — the file runs a fixed-point loop over named rewrites; attach `idiom_id: ?[]const u8` to each rewrite descriptor and set it for the rewrites matching Task 2 entries)
- Modify: JSON emission in `canonicalize.zig` / `json_diagnostics.zig` so `canonicalize --json` candidates carry `"idiom_id"`
- Test: in `canonicalize.zig`

**Interfaces:**
- Consumes: idiom IDs from Task 2 (`idiom.element-iteration`, `idiom.multi-field-read`, ...). `rewrite_rule` back-references in Task 2's table get filled in this task for every wired rewrite.
- Produces: `canonicalize --json` output rows with `idiom_id`; double-normalize idempotence guarantee.

- [x] **Step 1: Read the rewrite catalog.** Identify each existing rewrite that corresponds to a Task 2 idiom row. Map and record the pairs in a comment block at the top of the catalog. Any Task 2 row with no existing rewrite keeps `rewrite_rule = null` (advisory-only per spec 4.2.1).

**Result of the mapping, 2026-07-31: exactly one pair, not the several this task
assumed.** The catalog holds two rewrite families - line/column `Refactor` rows
(`canonicalize --json`) and span-keyed `StatementRewrite`s (`normalize`'s
rewrite trace). Every one of them repairs a canonical-profile *restriction*
(`let` to `const`, arrow to named function, exported function-valued const,
compound assignment, redundant bool compare, complex template interpolation,
ternary to match). The idiom table is a different axis: it picks among spellings
that are all admitted. Only ZTS619 `drop_unused_index_alias` sits on both - it
supersedes a non-idiomatic iteration spelling in favour of
`for (const item of items)`, which is the `idiom.element-iteration` row.

Three consequences for the plan as written:

1. **No `idiom_id` field was added anywhere.** With one wired rewrite and no
   `Refactor` kind mapping to a row, a field on both descriptors plus JSON
   plumbing on both surfaces would be dead weight. The back-reference runs the
   other way instead: `rewrite_rule` holds the `RepairIntent` tag name, which is
   already what `normalize --json` prints in `rewriteTrace`, and
   `idiom_registry.findByRewriteRule` resolves an applied intent to its row. No
   new JSON key, no schema change, and `describe-rule --idioms --json` already
   publishes the mapping. Revisit when Phase 6 lands the rows that do have
   rewrites.
2. **`idiom.element-iteration.superseded` gained a second spelling.** Spec 4.2.1
   lists only the `range(items.length)` form; ZTS619 rewrites the
   `items.entries()`-with-unread-index form. Same operation, same idiomatic
   target. **Spec edit owed:** add it to the table's non-idiomatic column.
3. A `rewrite_rule` is a bare string, so a test asserts every non-null one names
   a live `RepairIntent` member. Without it a renamed intent breaks the mapping
   silently.

- [x] **Step 2: Write the failing test**

```zig
test "canonicalize candidates carry idiom ids where wired" {
    // run canonicalize over a snippet that triggers one wired rewrite,
    // e.g. a for...of over range(items.length) that only indexes items
    // -> expect the candidate's idiom_id == "idiom.element-iteration"
}
```

Implement against the file's existing test harness (it has tests — copy the nearest candidate-shape assertion).

- [x] **Step 3: Implement** the `idiom_id` field, thread it to JSON output, fill Task 2's `rewrite_rule` fields for wired rows.

- [x] **Step 4: Idempotence property test.** Add (or extend, if one exists — grep for "idempot" first):

```zig
test "normalize is idempotent over examples" {
    // for each .ts/.tsx under examples/ that canonicalize accepts:
    // normalize once -> bytes A; normalize A -> bytes B; expect A == B
}
```

If a shell gate fits better than a Zig test, add the loop to `scripts/verify.sh` instead — one of the two must exist and run in CI.

**Both were built, because the corpus alone does not test the property.**
Measured 2026-07-31: of the 55 example handlers, 50 normalize to themselves in
zero passes, 1 is refused as not fully canonical, and only 4 trigger any rewrite
at all. A gate over that corpus is 91 percent vacuous - it would stay green
against a rewrite that oscillates on every construct the examples happen not to
use.

- `scripts/check-normalize-idempotent.sh`, wired into `scripts/verify.sh`:
  double-normalizes every `examples/` handler and compares bytes. Cheap, and it
  strengthens for free as examples are added.
- `test "normalize is byte-idempotent over every rewrite"` in `canonicalize.zig`
  (runs under `zig build test-canonicalize`, not `test-cli`): a table with one
  non-canonical source per rewrite the normalizer can apply. Each case asserts
  the first pass rewrote something (`iterations >= 1`), that pass two is
  byte-identical, and that pass two applied nothing - the last catches a rewrite
  that undoes itself, which byte-equality alone would pass. Add a row whenever a
  rewrite is added.

- [x] **Step 5: Run, expect PASS.** `zig build test-cli` (or the step that owns `packages/tools` tests — check `build.zig` test-step wiring first).

- [x] **Step 6: Commit**

```bash
zig fmt packages/tools/src/canonicalize.zig
git add -A && git commit -m "feat(canonicalize): attach idiom ids to rewrites and gate normalize idempotence"
```

### Task 6: honesty — exhaustiveness flag tells the truth

**Files:**
- Modify: `packages/zts/src/path_generator.zig:303` (`.exhaustive = self.tests.items.len < MAX_PATHS`) and the summarization sites for loop bodies
- Test: `path_generator.zig` (existing envelope test near line 2094 shows the harness)

**Interfaces:**
- Consumes: nothing new.
- Produces: `envelope.exhaustive == false` whenever any loop body was summarized once rather than path-expanded, or any recursive call was cut off — independent of `MAX_PATHS`. Downstream consumers (contract JSON, prove-behavior verdicts) read the same field, so no schema change.

- [x] **Step 1: Write the failing test**

```zig
test "envelope is not exhaustive when a loop body is summarized" {
    // handler with a for...of whose body branches:
    // for (const item of items) { if (item.ok) { ... } else { ... } }
    // -> generator summarizes the body once (spec gap 11)
    // expect envelope.exhaustive == false
}
```

Build it with the same harness as the test at line ~2094.

- [x] **Step 2: Run, expect FAIL** (today it reports exhaustive when under MAX_PATHS).

- [x] **Step 3: Implement.** Add a `summarized: bool = false` flag on the generator; set it at every site that emits a summarized loop skeleton or truncates recursion (find them: grep the file for the loop-handling and MAX_PATHS sites). Change line 303 to `.exhaustive = !self.summarized and self.tests.items.len < MAX_PATHS`.

**Three things the plan's one-line change did not account for, 2026-07-31.**

1. **The predicate is written twice, independently.** `path_generator.zig:303`
   sets `envelope.exhaustive`, and `precompile.zig:964` separately computes
   `paths_exhaustive = tests.len < MAX_PATHS` for the proof-trace summaries and
   the `check` display. Fixing only the first leaves every "Checked across N
   enumerated path(s) (exhaustive)" summary still over-claiming. The predicate
   now lives once, as `PathGenerator.pathsExhaustive()`, and both read it.
2. **`cost_bounded` was conjoined with `exhaustive`** at `precompile.zig:980`
   and `:2016`. Left alone, this task would have stripped `cost_bounded` from
   every loop-bearing handler - a much larger and wrong claim change, since a
   summarized loop still carries a symbolic linear bound in the collection's
   length. The conjunct was already redundant: truncation forces
   `envelope.total` to `.unbounded`, so the class test alone covered it. Dropped
   from both, with the truncation-to-unbounded coupling in `buildCostEnvelope`
   re-keyed onto truncation specifically rather than onto `exhaustive`.
3. **The `check` display named the wrong cause.** Its non-exhaustive branch
   printed "(limit reached)", which is false for a summarized handler. It now
   distinguishes the two: "(limit reached)" only at `MAX_PATHS`, otherwise
   "(summarized: a loop body is walked once, not enumerated)".

Recursion truncation is deliberately not wired into `summarized` here; it is
Task 7's subject and is set there if that task finds a claim to downgrade.

- [x] **Step 4: Run, expect PASS**, then the full engine suite: `zig build test-zts`. Fix downstream tests that asserted `exhaustive == true` over loop-bearing handlers — those assertions were the bug this task exists to fix; update them to expect `false` and leave a one-line comment citing spec gap 11.

- [x] **Step 5: Commit**

```bash
zig fmt packages/zts/src/path_generator.zig
git add -A && git commit -m "fix(paths): summarized loops and cut recursion clear the exhaustive flag"
```

### Task 7: honesty — no totality or bounded-cost claim for unproven recursion

**Files:**
- Modify: `packages/zts/src/handler_verifier.zig` (the recursive tree walk — file header comment at line 15 confirms the shape) and/or `packages/zts/src/path_generator.zig` cost-bound sites (lines ~302-353, `envelope.total` / `Bound`)
- Test: alongside the modified file

**Interfaces:**
- Consumes: nothing new.
- Produces: a handler containing direct or mutual recursion reports its cost bound as unbounded/unavailable and any totality-adjacent property as unproven, unless a decreasing argument is proven (none is, in Phase 0 — so recursion always downgrades). Spec 5.6: "No runtime stack cap may be presented as a termination proof."

- [x] **Step 1: Locate the claim.** Trace how a recursive handler flows today: does `handler_verifier` or the contract builder emit any field a consumer reads as total/bounded (`envelope.total` constant bound, contract properties)? Record findings as a comment in the test added next. If the claim genuinely cannot be produced today for recursive input, this task reduces to adding the pinning test that proves it — that is a valid outcome.

**Findings, 2026-07-31. The totality half was already honest; the cost half was
not.**

- **Totality: no change needed.** `spec_discharge.CapsuleFacts.holds` returns
  false for every property, `total` included, whenever `recursive` is set. A
  recursive helper is already refused capsule discharge with its own suggestion
  text. Nothing to downgrade.
- **Cost: a live over-claim.** Measured on a handler whose recursive helper
  calls `sqlOne` once per level, with the level count taken from the request:
  `cost_bounded PROVEN`, `Max I/O depth: 0`, `Execution paths: 1 (exhaustive)`.
  All three false.
- **Why it is that wrong: the path generator never walks into user functions at
  all.** Verified by comparing a module call inline in the handler
  (`Max I/O depth: 1`) against the identical call moved into a one-line
  non-recursive helper (`Max I/O depth: 0`). So the cost envelope counts only
  the module calls written syntactically in the handler body.

That last point is a real defect **wider than this task**: every helper's module
calls are uncounted, recursive or not. Fixing it is whole-program cost analysis,
not Phase 0, and it is **not** fixed here. Task 7 covers only what it names -
recursion must not yield a constant cost bound - and the fix is keyed on
recursion, with a test pinning that a non-recursive helper keeps its bound. The
general under-count is recorded here for a later phase to pick up.

- [x] **Step 2: Write the failing (or pinning) test**

```zig
test "recursive handler gets no constant cost bound" {
    // function depth(n) { if (n === 0) { return 0; } return depth(n - 1) + 1; }
    // wrapped in a handler; expect the cost envelope for the recursive path
    // to be unbounded/absent, not a constant, and no total/proven marker.
}
```

- [x] **Step 3: Implement** recursion detection where the claim is emitted: build the call graph the verifier already walks, detect a cycle reaching the handler, and force the bound to the unbounded variant (`contract_types.Bound` — read its variants first) and any proof-ish marker to its unproven variant.

**No new call graph was built.** `effect_inference.Analyzer` already builds one
(CSR-encoded) and already marks `row.recursive` via a Tarjan-style pass. What was
missing is a reachability query: `propagate` deliberately resets `recursive` to
each function's own value, because a caller of a recursive helper is not itself
recursive and must not lose capsule discharge for one. A cost claim needs the
other question, so `Analyzer.reachesRecursion` walks the existing graph.

Three details worth carrying forward:

1. **Key on the body node, not the declaration.** `findHandlerFunction` returns
   the `.function_expr`; the analyzer records the enclosing `.function_decl`.
   They are adjacent indices and never equal, so matching on `decl_node`
   silently returned false for every handler. The body is the node both agree
   on.
2. **Hand the analyzer the program root, not the handler.** It collects
   functions by walking down from its argument, so given `handler_func` it never
   sees the sibling declarations the handler calls.
3. **Fail closed.** No program root, no analyzable handler function, or an
   analysis that could not allocate all set `reaches_recursion = true`. Absence
   of evidence is not proof of termination.

The `check` display needed a third rework. Task 6 gave its non-exhaustive branch
the wording "summarized: a loop body is walked once", which is the wrong cause
for a recursive handler with no loop in it. Cause and message now travel
together as `PathGenerator.Coverage`, whose four cases each carry their own note,
replacing the bool-plus-guesswork the display had been doing.

- [x] **Step 4: Run, expect PASS**, then `zig build test-zts` and `zig build test` for contract consumers.

- [x] **Step 5: Commit**

```bash
zig fmt packages/zts/src/handler_verifier.zig packages/zts/src/path_generator.zig
git add -A && git commit -m "fix(verify): recursion never yields totality or constant cost claims"
```

### Task 8: phase gate

**Files:**
- Modify: `docs/plans/2026-07-30-012-zts-advanced-rev4-master-plan.md` (Decision log)

- [x] **Step 1: Full local gate.** Run in order; all green:

```bash
zig build test
bash scripts/test-examples.sh
bash scripts/verify.sh
```

- [x] **Step 2: Spec drift.** `./zig-out/bin/zts spec-check --json` — green (ternary node rule pre-existed; confirm no drift from Task 4).

- [x] **Step 3: Manual smoke.** `./zig-out/bin/zts check` on a handler using a pure ternary — no diagnostics; on a chained ternary — ZTS chain code with repair; `describe-rule --json` lists `advisory` severity and `idiom.` IDs.

**Results, 2026-07-31.** All met except the severity half of the last clause.

| Check | Result |
|---|---|
| pure `?:` | `Strict ZigTS ........... OK` |
| chained `?:` | `ZTS621 error` at 4:20, help names `match` / if-else |
| impure `?:` | `ZTS612 error` at 4:21, help names binding the call first |
| `describe-rule ZTS612`/`ZTS621` | both `repair_intent: replace_ternary_with_if` |
| `describe-rule --idioms --json` | 12 rows, all `idiom.`-prefixed, 1 wired |
| `normalize` on a chain | unchains the outer, keeps the freed inner `?:` |
| `spec-check --json` | `ok: true`, no drift from Task 4 |

Two clarifications on what the smoke did *not* show:

1. **`check --json` carries no repair intent for any rule.** Its diagnostic
   shape is `{code, severity, message, file, line, column, suggestion}`.
   Confirmed against the pre-existing ZTS613, which has the same keys, so ZTS621
   behaves exactly like every other rule. Repair intents are published through
   `describe-rule --json` and the canonicalize surfaces, not here.
2. **`advisory` is not observable in `describe-rule` output**, because rule
   entries carry no severity field and no rule is assigned `advisory` yet. The
   severity exists, is isolated from exit codes and success, and is tested; the
   idiom channel that will emit it is Phase 6, and the `severities` list the
   spec requires is part of Phase 1's `meta` payload. This is the same shape as
   the `warning`-assigned-to-zero-rules debt the master plan already tracks.

- [x] **Step 4: Record decisions.** Append to the master plan's Decision log: D1-interim assignability adopted at `type_checker.zig joinTypes`; D2-interim purity adopted at `strict_checker.zig isPureExpr`; both cite retirement conditions (D1/D2 landing).

- [x] **Step 5: Commit**

```bash
git add -A && git commit -m "docs(plans): record phase 0 completion and interim decisions"
```

## Self-review notes

- Spec coverage for the phase-0 scope: pure `?:` (Tasks 3-4), advisory + idiom infrastructure (Tasks 1-2, 5), honesty items gaps 10-11 (Tasks 6-7). Deliberately excluded from Phase 0 and covered by later phases in the master plan: match upgrades, null, `??` diagnostics, protocol, stdlib.
- Types referenced across tasks: `Severity.advisory` (Task 1) used in Task 5-6 emission paths only via existing diagnostic structs; `canonical_ternary_impure`/`canonical_ternary_chain` (Task 3) referenced in Task 3's registry sweep only; `joinTypes` local to Task 4; idiom IDs (Task 2) referenced by Task 5 strings.
- Steps that begin with "read/locate" are real steps, not placeholders: each names the file, the line anchor, and what to confirm, and the deliverable code follows in the same task.

# Phase 1: registry consolidation and the v2 agent protocol — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the section-12 restriction matrix a generated registry with the same
standing as the rule and idiom registries, and ship `zts agent --stdin-json`: one
request object in, one response envelope out, over the eight operations that wrap
work the compiler already does.

**Architecture:** Two independent halves that meet only in the `meta` payload.
The registry half adds `packages/zts/src/restriction_registry.zig` next to the
existing `rule_registry.zig` and `idiom_registry.zig`, and re-points the
hand-written blocked-feature table in `packages/tools/src/json_diagnostics.zig` at
it, leaving the v1 `features` / `restrictions` output byte-identical. The protocol
half adds three files under `packages/tools/src/`: `agent_identity.zig` (profile
id, source digests, canonical paths), `module_graph_record.zig` (the resolved
graph and its digest, D3 §3), and `agent_protocol.zig` (envelope, negotiation,
error object, staleness guard, operation dispatch). Every operation calls an
existing core - `precompile.runCheckOnlyWithOptions`, `canonicalize.collect`,
`canonicalize.normalize`, `rule_registry`, `idiom_registry` - and writes a fresh
snake_case payload. No v1 emitter is edited, so "v1 surfaces byte-identical" holds
by construction rather than by test alone.

**Tech Stack:** Zig 0.16.0, `std.json.Stringify` for every v2 byte,
`std.json.parseFromSlice` for the request, `zig build test-zts` /
`zig build test-zts-cli` / `zig build test-canonicalize`, `bash scripts/verify.sh`,
`zig fmt`.

## Global Constraints

- Spec source of truth: `docs/zts-formal-spec-northstar-advanced.md` revision 4.
  Cited: the normative agent protocol (4.8, lines 460-693), the
  restriction-to-theorem matrix (12, lines 2204-2241), the closed severity set and
  success rule (4.8, lines 604-614), the idiom table (4.2.1).
- Design source of truth: `docs/plans/2026-07-30-016-d3-canonical-form-wire-design.md`
  §3 (digests and pre-images), §6 (payload schemas, frozen negotiation, error
  codes, determinism), §7 (Phase 1 needs §3 and §6).
- Master-plan ground rule 3 is binding here: **no meta payload content is ever
  hand-written.** A section that cannot be generated from a registry is absent
  from the payload and listed in `deferred_sections`, never stubbed with prose.
- Every field name on the v2 wire is `snake_case`. v1 shapes are frozen and
  untouched: no edit to `json_diagnostics.writeErrorJson` /`writeSuccessJson`,
  `expert_meta.writeJson`, `describe_rule.writeRuleJson`,
  `canonicalize.writeJson` / `writeNormalizeJson`.
- Within schema version 2 a field is never removed, renamed, or given a new
  meaning. Adding an optional field is allowed.
- Determinism: `agent` writes exactly one JSON object plus a trailing newline to
  stdout and nothing else. Every log, warning, and progress line goes to stderr.
  Array order is fixed by the code that produces it, never by hash-map iteration.
- Exit code: `agent` exits 0 whenever it wrote a well-formed response, including a
  response carrying a protocol `error` object or `"success": false`. A non-zero
  exit means the process could not produce a response at all. This differs from
  `zts check --json` (exit 1 on errors) on purpose - the envelope carries the
  verdict.
- Every task: `zig fmt` on touched files before commit; tests in `test "..."`
  blocks next to the code; run the named test step before and after; commit per
  task; never push.
- End-state gate: `bash scripts/verify.sh` green, `zig build test` green,
  `bash scripts/test-examples.sh` green.

---

### Task 1: identity primitives - profile id, source digest, canonical path

**Files:**
- Create: `packages/tools/src/agent_identity.zig`
- Test: in the same file

**Interfaces:**
- Consumes: nothing.
- Produces: `pub const profile_id = "zts-advanced-1"`,
  `pub const schema_version: u32 = 2`,
  `pub const supported_schema_versions = [_]u32{2}`,
  `pub fn sourceDigest(bytes: []const u8) [64]u8`,
  `pub fn canonicalRoot(allocator, root: []const u8) ![]u8`,
  `pub fn canonicalRelPath(allocator, canonical_root: []const u8, path: []const u8) ![]u8`,
  `pub const PathError = error{ PathOutsideProjectRoot, ProjectRootUnresolvable }`.
  Tasks 4, 5, 8, 9, 10 all call these. This file lives in `tools`, not `zts`,
  because the neighbouring identity constants (`compiler_version`,
  `policy_version`, `mode`) already live in `packages/tools/src/expert_meta.zig`,
  and putting it in `zts` would need a new `scripts/module-boundary.allow` row for
  no gain.

**Two deviations, both found while running this task on 2026-07-31.**

1. **Zig 0.16 removed `std.fs.cwd()`.** Every filesystem call goes through an
   `std.Io` instance (`std.Io.Dir.realPathFileAlloc(.cwd(), io, path, allocator)`),
   so both path functions take an `io: std.Io` parameter the plan's signatures
   omitted. Callers build the backend the way the rest of `tools` does:
   `std.Io.Threaded.init(allocator, .{ .environ = .empty })`. Tests pass
   `std.testing.io`. Tasks 4, 5, 8, 9, and 10 inherit the extra parameter.
2. **A re-export is not a reference, so the file needs its own test root.** The
   plan's Step 2 assumed adding `pub const agent_identity = @import(...)` to
   `zts_cli.zig` puts the file's tests into `zig build test-zts-cli`. It does not:
   Zig collects tests only from files it analyzes, and an unreferenced `pub const`
   import is compiled by AstGen alone. Measured - with the file wired that way, a
   deliberately wrong `expectEqualStrings` **and** a call to the nonexistent
   `std.fs.cwd()` both passed the step, and the test count stayed at 82. The file
   gets a `test-agent-identity` row in `build.zig`'s `host_test_roots` table,
   which `zig build test` picks up automatically (build.zig:701).

   **Pre-existing hole found by the same probe, not fixed here:**
   `packages/tools/src/verify_paths_core.zig` calls `tmp_dir.dir.realpath(path, &buf)`
   at lines 169, 201, and 233, which does not compile against 0.16
   (`Io.Dir.realPath` takes `io`). Its three tests have therefore never run. Rooting
   that file as a test target fails with `member function expected 2 argument(s),
   found 1` on all three. Any file in `tools` that is re-exported but never called
   is in the same state; an audit belongs in its own commit.

- [x] **Step 1: Write the failing tests**

```zig
const std = @import("std");

test "sourceDigest is lowercase hex sha256" {
    const empty = sourceDigest("");
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &empty,
    );
    const abc = sourceDigest("abc");
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &abc,
    );
}

test "canonicalRelPath returns a root-relative slash path" {
    const a = std.testing.allocator;
    const rel = try canonicalRelPath(a, "/project", "/project/src/handler.ts");
    defer a.free(rel);
    try std.testing.expectEqualStrings("src/handler.ts", rel);
}

test "canonicalRelPath collapses dot segments" {
    const a = std.testing.allocator;
    const rel = try canonicalRelPath(a, "/project", "/project/src/../src/./handler.ts");
    defer a.free(rel);
    try std.testing.expectEqualStrings("src/handler.ts", rel);
}

test "canonicalRelPath rejects a path outside the project root" {
    const a = std.testing.allocator;
    try std.testing.expectError(
        error.PathOutsideProjectRoot,
        canonicalRelPath(a, "/project", "/project/../secrets.ts"),
    );
    try std.testing.expectError(
        error.PathOutsideProjectRoot,
        canonicalRelPath(a, "/project", "/project-other/handler.ts"),
    );
}

test "canonicalRelPath maps the root itself to the empty string" {
    const a = std.testing.allocator;
    const rel = try canonicalRelPath(a, "/project", "/project");
    defer a.free(rel);
    try std.testing.expectEqualStrings("", rel);
}
```

- [x] **Step 2: Run, expect failure** (file missing).

Run: `zig build test-zts-cli -- --test-filter "canonicalRelPath"`
Expected: compile error, `agent_identity.zig` not found / not imported.

Wire the new file into the tools test surface the same way a sibling does: add
`pub const agent_identity = @import("agent_identity.zig");` to the re-export block
at the top of `packages/tools/src/zts_cli.zig` (lines 3-16), which is what
`zig build test-zts-cli` roots on.

- [x] **Step 3: Implement**

```zig
//! Identity primitives for the version-2 agent protocol.
//!
//! Spec 4.8 requires every response to bind a profile identity and every file
//! path to resolve inside an explicit, canonicalized project root. D3 §3 fixes
//! the digest algorithm (SHA-256, lowercase hex, 64 characters) and the
//! canonical path form (absolute, symlinks resolved, dot segments removed,
//! project-root-relative, `/` separators).

const std = @import("std");

/// The profile this binary implements. Published in every response envelope and
/// compared against `expected.profile_id`.
pub const profile_id = "zts-advanced-1";

/// The only schema version this binary serves. A request naming any other
/// version gets the frozen negotiation response (agent_protocol.zig).
pub const schema_version: u32 = 2;
pub const supported_schema_versions = [_]u32{2};

pub const PathError = error{
    PathOutsideProjectRoot,
    ProjectRootUnresolvable,
};

/// SHA-256 of the raw bytes, lowercase hex. D3 §3: `source_digest` hashes the
/// file as it sits on disk, uncanonicalized, because repair spans are byte
/// offsets into exactly these bytes.
pub fn sourceDigest(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Canonicalize the project root: absolute, symlinks resolved. A root that does
/// not exist is unresolvable, not silently accepted - every later path check
/// depends on this prefix being real.
pub fn canonicalRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fs.cwd().realpathAlloc(allocator, root) catch
        return error.ProjectRootUnresolvable;
}

/// Resolve `path` against an already-canonical root and return the
/// root-relative form. Rejects anything that escapes the root.
///
/// Existing files go through `realpath` so a symlink out of the tree is caught;
/// a path that does not exist yet resolves lexically, which is enough because a
/// lexical resolve cannot re-enter the root after leaving it.
pub fn canonicalRelPath(
    allocator: std.mem.Allocator,
    canonical_root: []const u8,
    path: []const u8,
) ![]u8 {
    const joined = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else
        try std.fs.path.resolve(allocator, &.{ canonical_root, path });
    defer allocator.free(joined);

    const resolved = std.fs.cwd().realpathAlloc(allocator, joined) catch
        try std.fs.path.resolve(allocator, &.{joined});
    defer allocator.free(resolved);

    if (std.mem.eql(u8, resolved, canonical_root)) return allocator.dupe(u8, "");
    if (!std.mem.startsWith(u8, resolved, canonical_root)) return error.PathOutsideProjectRoot;
    if (resolved.len <= canonical_root.len or resolved[canonical_root.len] != std.fs.path.sep) {
        return error.PathOutsideProjectRoot;
    }
    return allocator.dupe(u8, resolved[canonical_root.len + 1 ..]);
}
```

The tests pass `/project`, which does not exist on disk, so the `realpathAlloc`
fallback path is the one under test. Keep the fallback: it is also the production
path for a file the client names before creating it.

- [x] **Step 4: Run, expect PASS**

Run: `zig build test-zts-cli -- --test-filter "canonicalRelPath"` then
`zig build test-zts-cli -- --test-filter "sourceDigest"`
Expected: PASS (5 tests).

- [x] **Step 5: Commit**

```bash
zig fmt packages/tools/src/agent_identity.zig packages/tools/src/zts_cli.zig
git add -A && git commit -m "feat(agent): add v2 identity primitives - profile id, source digest, canonical paths"
```

---


**Deviations and findings, 2026-07-31.**

1. **Every `enforced_by` entry was measured, and six rows have no enforcement.**
   Running a minimal handler per construct through `zts check --json` found that
   `eval`, numeric record keys, object methods, getters, and mutable live
   iteration produce no diagnostic at all, and that `interface` is still admitted
   by decision. Each carries an `unenforced_note` naming the measurement rather
   than an invented code. Two enforcement details also came out different from
   the obvious guess: `async/await` is rejected by the parser's expected-token
   path (ZTS002), not the unsupported-feature path, and multiple record spreads
   are caught by ZTS614.
2. **ZTS041 is two different diagnostics.** `parserErrorCode` maps
   `nesting_too_deep` to ZTS041 and `stripErrorCode` maps the `any`-type
   rejection to the same code (`json_diagnostics.zig:96` and `:234`). The
   type-evidence row lists the measured stripper codes (ZTS041 `any`, ZTS042
   `as`, ZTS043 `satisfies`) and records the collision inline. Not fixed here.
3. **The allowlist row landed with Task 3, not Task 2**, because the gate rejects
   a row nothing uses: `tools restriction_registry` is only reached once
   `json_diagnostics` projects from it.
4. **`zts check` does not terminate on `delete` inside a function body.**
   Found while measuring the `delete` row:
   `export function handler(req) { const o = {a: 1}; delete o.a; return Response.json({}); }`
   runs past 40 seconds with no output. The same statement at module scope
   reports ZTS001 in milliseconds. Unrelated to this phase, not fixed, recorded
   here so it is not rediscovered.

### Task 2: the restriction registry

**Files:**
- Create: `packages/zts/src/restriction_registry.zig`
- Modify: `packages/zts/src/root.zig` (internal-tier re-export, next to `rule_registry`)
- Modify: `scripts/module-boundary.allow` (add `tools restriction_registry`)
- Test: in `restriction_registry.zig`

**Interfaces:**
- Consumes: `rule_registry.findByCode` for the enforcement gate.
- Produces:

```zig
pub const Nature = enum { essential, replaced, canonical_simplicity, language_simplicity, provisional };
pub const RestrictionEntry = struct {
    id: []const u8,
    feature: []const u8,
    boundary: []const u8,
    nature: Nature,
    note: []const u8,
    alternative: ?[]const u8,
    failure_class: ?[]const u8,
    proof_unlocked: ?[]const u8,
    enforced_by: []const []const u8,
    unenforced_note: ?[]const u8,
    v1_feature_name: ?[]const u8,
};
pub const entries: []const RestrictionEntry;
pub fn findById(id: []const u8) ?*const RestrictionEntry;
pub fn matrixHash() [64]u8;
```

Task 3 reads `entries` (filtered on `v1_feature_name != null`) to rebuild the v1
features table. Task 7 emits the whole set on the v2 wire. Task 11 publishes
`matrixHash()` in `meta`.

**Two decisions this task makes, both recorded in the master plan's decision log
at Task 12:**

1. **The matrix is its own registry, not rows in `all_rules`.** A restriction is
   not a diagnostic: it has no code, no severity, and no repair, and several rows
   are enforced by the parser rather than by a rule. Folding them into `all_rules`
   would also shift `policy_hash` and the `rule_count` every consumer asserts on.
   The matrix gets its own `matrixHash()`, exactly as the idiom table got its own
   surface in Phase 0.
2. **v1 output is frozen at today's row set.** The spec-12 matrix has rows the v1
   `features` table never published (`eval`/dynamic import, ambient async,
   unchecked recursive cycle, effectful `?:`, chained conditional arms, numeric
   record keys, multiple record spreads, fallback `assert`, object methods). A row
   carries `v1_feature_name` only when the v1 table already published it, and the
   v1 emitter filters on that field. New rows reach clients through the v2
   `restrictions` operation and `meta` only.

- [x] **Step 1: Capture the v1 baseline before touching anything**

```bash
zig build
./zig-out/bin/zts features --json > /tmp/features.v1.json
./zig-out/bin/zts restrictions --json > /tmp/restrictions.v1.json
./zig-out/bin/zts features > /tmp/features.v1.txt
./zig-out/bin/zts restrictions > /tmp/restrictions.v1.txt
```

These four files are the acceptance criterion for Task 3. `features --json`,
`modules --json`, and `restrictions --json` are already pinned by
`packages/tools/tests/fixtures/contract/*.golden.json` (build.zig:580-582), so the
build gate covers the JSON pair; the text pair is covered by hand comparison in
Task 3 Step 5.

- [x] **Step 2: Write the failing tests**

```zig
const std = @import("std");
const rule_registry = @import("rule_registry.zig");

test "every restriction id is unique and prefixed" {
    for (entries, 0..) |entry, i| {
        try std.testing.expect(std.mem.startsWith(u8, entry.id, "restriction."));
        for (entries[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, entry.id, other.id));
        }
    }
}

test "every restriction names its enforcement or says why it cannot" {
    for (entries) |entry| {
        const has_codes = entry.enforced_by.len > 0;
        const has_note = entry.unenforced_note != null;
        // Exactly one: a row either points at the rules that reject the
        // construct, or states in one line why no rule does. Silence is the
        // failure mode this gate exists to prevent.
        try std.testing.expect(has_codes != has_note);
    }
}

test "every enforcing code resolves to a live rule or a known non-registry band" {
    for (entries) |entry| {
        for (entry.enforced_by) |code| {
            if (rule_registry.findByCode(code) != null) continue;
            // ZTS0xx parser errors and ZTS2xx type-checker errors are real
            // diagnostic codes that deliberately live outside the policy-hashed
            // registry (see describe_rule.zig's findTypeCheckerRule fallback).
            const parser_band = std.mem.startsWith(u8, code, "ZTS0");
            const typeck_band = std.mem.startsWith(u8, code, "ZTS2");
            if (parser_band or typeck_band) continue;
            std.debug.print("restriction {s} names unknown code {s}\n", .{ entry.id, code });
            try std.testing.expect(false);
        }
    }
}

test "the v1 projection keeps every name the v1 table published" {
    var v1_count: usize = 0;
    for (entries) |entry| {
        if (entry.v1_feature_name != null) v1_count += 1;
    }
    // The v1 features table publishes 20 blocked rows. Task 3 asserts the exact
    // strings; this pins the count so a row cannot silently leave the v1 set.
    try std.testing.expectEqual(@as(usize, 20), v1_count);
}

test "matrixHash is stable and changes with the matrix" {
    const h = matrixHash();
    try std.testing.expectEqual(@as(usize, 64), h.len);
    try std.testing.expectEqualSlices(u8, &h, &matrixHash());
}
```

- [x] **Step 3: Run, expect failure** (file missing).

Run: `zig build test-zts -- --test-filter "restriction"`

Add `pub const restriction_registry = @import("restriction_registry.zig");` to the
internal-tier block of `packages/zts/src/root.zig` - copy the line style of the
neighbouring `pub const rule_registry` / `pub const idiom_registry` entries.

- [x] **Step 4: Transcribe the matrix**

Read `docs/zts-formal-spec-northstar-advanced.md` lines 2209-2229 (the table) and
`packages/tools/src/json_diagnostics.zig` lines 678-880 (the v1 `features` array).
Every blocked v1 row becomes an entry carrying its existing
`alternative` / `blocked_reason` / `failure_class` / `proof_unlocked` strings
**verbatim** - Task 3 depends on byte equality. Order the file so the 20 v1 rows
appear first, in the exact order they appear in the v1 array, then the spec-12
rows that v1 never published.

Header and the shape of the first three entries:

```zig
//! Machine-readable view of the restriction-to-theorem matrix (spec 12).
//!
//! A restriction is a construct the profile refuses, paired with the boundary
//! the refusal protects and the nature of the decision: essential to a proof, or
//! a simplicity choice the profile makes deliberately. Spec 12 requires this
//! matrix be generated from the versioned profile registry rather than
//! maintained as prose; this file is that registry.
//!
//! A restriction is not a rule. It carries no code, no severity, and no repair,
//! and several rows are enforced by the parser rather than by a registry rule,
//! so the rows live here instead of in `rule_registry.all_rules` - where they
//! would also shift the policy hash and the rule counts every consumer asserts.
//!
//! `v1_feature_name` marks the rows the v1 `zts features` / `zts restrictions`
//! output already published. That output is frozen: it emits exactly the marked
//! rows, in this file's order, with these strings. Rows added here after the
//! freeze reach clients through the v2 `restrictions` operation only.

const std = @import("std");
const rule_registry = @import("rule_registry.zig");

/// Spec 12 column 3, as a closed set rather than prose.
pub const Nature = enum {
    /// No known way to keep the proof and the construct.
    essential,
    /// A different construct provides the capability with the proof intact.
    replaced,
    /// One explicit form is easier to read and maintain; not a theorem.
    canonical_simplicity,
    /// A smaller language is the goal; not a theorem.
    language_simplicity,
    /// Kept pending a measurement named in the spec.
    provisional,

    pub fn label(self: Nature) []const u8 {
        return switch (self) {
            .essential => "essential",
            .replaced => "replaced",
            .canonical_simplicity => "canonical_simplicity",
            .language_simplicity => "language_simplicity",
            .provisional => "provisional",
        };
    }
};

pub const RestrictionEntry = struct {
    /// Stable identifier, `restriction.<slug>`. Never renamed once published.
    id: []const u8,
    /// The excluded or constrained feature, as spec 12 column 1 names it.
    feature: []const u8,
    /// The boundary the cut protects, spec 12 column 2.
    boundary: []const u8,
    nature: Nature,
    /// The rest of spec 12 column 3, after the nature classification.
    note: []const u8,
    /// What to write instead.
    alternative: ?[]const u8,
    /// The failure class the cut prevents, as the v1 table words it.
    failure_class: ?[]const u8,
    /// The proof the cut unlocks, as the v1 table words it.
    proof_unlocked: ?[]const u8,
    /// Diagnostic codes that reject the construct. Empty only when
    /// `unenforced_note` says why.
    enforced_by: []const []const u8,
    /// One line naming why no diagnostic enforces this row today.
    unenforced_note: ?[]const u8 = null,
    /// The name this row carries in the frozen v1 `features` output, or null
    /// when v1 never published it.
    v1_feature_name: ?[]const u8 = null,
};

pub const entries = [_]RestrictionEntry{
    .{
        .id = "restriction.switch-case",
        .feature = "switch/case",
        .boundary = "non-exhaustive control flow",
        .nature = .replaced,
        .note = "replaced by match, whose arms are checked for coverage",
        .alternative = "use 'match' expression",
        .failure_class = "non-exhaustive control flow and implicit fallthrough",
        .proof_unlocked = "match coverage and exhaustive return analysis",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "switch/case",
    },
    .{
        .id = "restriction.var",
        .feature = "var",
        .boundary = "block-scoped data flow",
        .nature = .replaced,
        .note = "replaced by let and const",
        .alternative = "use 'let' or 'const'",
        .failure_class = "scope hoisting and temporal dead zones",
        .proof_unlocked = "block-scoped data flow and reachability analysis",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "var",
    },
    // ... the remaining 18 v1 rows, in v1 order, then the spec-12-only rows.
};
```

For each row, find the enforcing code before writing it, do not guess:

```bash
./zig-out/bin/zts describe-rule --json | python3 -c "
import json,sys
for r in json.load(sys.stdin):
    print(r['code'], r['name'], '-', r['description'][:70])
" | sort
```

and for parse-level refusals, `grep -n "unsupported_feature" packages/zts/src/parser/*.zig`
shows which constructs raise ZTS001. A row you cannot tie to a code gets
`.enforced_by = &.{}` plus a one-line `.unenforced_note` - the second test above
forces the choice to be explicit either way.

- [x] **Step 5: Implement lookup and the hash**

```zig
pub fn findById(id: []const u8) ?*const RestrictionEntry {
    for (&entries) |*entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

/// Deterministic SHA-256 over the matrix, field-wise with `\0` separators and a
/// `\x01` record terminator - the same pre-image shape `rule_registry`'s policy
/// hash uses (D3 §3). Published as `restriction_matrix_hash`.
var cached_hash: ?[64]u8 = null;

pub fn matrixHash() [64]u8 {
    if (cached_hash) |h| return h;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (&entries) |*entry| {
        hasher.update(entry.id);
        hasher.update("\x00");
        hasher.update(entry.feature);
        hasher.update("\x00");
        hasher.update(entry.boundary);
        hasher.update("\x00");
        hasher.update(entry.nature.label());
        hasher.update("\x00");
        hasher.update(entry.note);
        hasher.update("\x00");
        hasher.update(entry.alternative orelse "");
        hasher.update("\x00");
        for (entry.enforced_by) |code| {
            hasher.update(code);
            hasher.update(",");
        }
        hasher.update("\x01");
    }
    cached_hash = std.fmt.bytesToHex(hasher.finalResult(), .lower);
    return cached_hash.?;
}
```

- [x] **Step 6: Run, expect PASS**

Run: `zig build test-zts -- --test-filter "restriction"`
Expected: PASS (5 tests).

- [x] **Step 7: Boundary row.** Add `tools restriction_registry` to
`scripts/module-boundary.allow` in the `# tools` block, keeping alphabetical order
(it sits between `repair_intent` and `route_match`). Task 3 is the reach that
justifies it; the gate fails a row nothing uses, so this must land with Task 3 or
in the same commit.

Run: `zig build test-module-boundary`
Expected: PASS.

- [x] **Step 8: Commit**

```bash
zig fmt packages/zts/src/restriction_registry.zig packages/zts/src/root.zig
git add -A && git commit -m "feat(registry): generate the section-12 restriction matrix from a registry"
```

---

### Task 3: v1 features and restrictions read the registry

**Files:**
- Modify: `packages/tools/src/json_diagnostics.zig:664-880` (the `Feature` struct
  and the blocked half of the `features` array)
- Test: in `json_diagnostics.zig`

**Interfaces:**
- Consumes: `restriction_registry.entries` from Task 2.
- Produces: no shape change. `writeFeaturesJson`, `writeFeaturesText`,
  `writeRestrictionsJson`, `writeRestrictionsText`, `writeRestrictionsMarkdown`,
  and `lookupRestriction` keep their signatures and their bytes. The 20 blocked
  rows now come from the registry; the allowed rows stay a local table (they are
  not restrictions and spec 12 does not cover them).

- [x] **Step 1: Write the failing test**

```zig
test "blocked features project from the restriction registry" {
    const restriction_registry = zts.restriction_registry;
    var blocked: usize = 0;
    for (features) |f| {
        if (f.status != .blocked) continue;
        blocked += 1;
        const entry = blk: {
            for (restriction_registry.entries) |*e| {
                const name = e.v1_feature_name orelse continue;
                if (std.mem.eql(u8, name, f.name)) break :blk e;
            }
            std.debug.print("blocked feature {s} has no registry row\n", .{f.name});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqualStrings(entry.alternative.?, f.alternative.?);
        try std.testing.expectEqualStrings(entry.failure_class.?, f.failure_class.?);
        try std.testing.expectEqualStrings(entry.proof_unlocked.?, f.proof_unlocked.?);
    }
    try std.testing.expectEqual(@as(usize, 20), blocked);
}
```

- [x] **Step 2: Run, expect FAIL** - today the two tables are unrelated, so a
string mismatch or a missing row fires.

Run: `zig build test-zts-cli -- --test-filter "restriction registry"`

- [x] **Step 3: Implement the projection.** Replace the 20 blocked literals in the
`features` array with a comptime concatenation:

```zig
/// The blocked half of the table is the restriction matrix, projected. Spec 12
/// owns the rows; this file owns only the v1 wire shape, which is frozen.
const blocked_features = blk: {
    var out: [restriction_registry.entries.len]Feature = undefined;
    var n: usize = 0;
    for (restriction_registry.entries) |entry| {
        const name = entry.v1_feature_name orelse continue;
        out[n] = .{
            .name = name,
            .status = .blocked,
            .alternative = entry.alternative,
            .blocked_reason = entry.note,
            .failure_class = entry.failure_class,
            .proof_unlocked = entry.proof_unlocked,
        };
        n += 1;
    }
    const fixed = out[0..n].*;
    break :blk fixed;
};

const features = allowed_features ++ blocked_features;
```

`blocked_reason` maps to the registry's `note`, so Task 2's transcription must have
put the v1 `blocked_reason` string in `note` for every v1 row. If a row's spec-12
note and its v1 `blocked_reason` differ, keep the v1 string in `note` and put the
spec wording in `boundary`; the v1 bytes are the constraint, and the spec column
that has no v1 counterpart is `boundary`, which v1 never emitted.

- [x] **Step 4: Run, expect PASS**, then the goldens:

Run: `zig build test-zts-cli` then `zig build test-contract-golden`
Expected: PASS. `features.golden.json` and `restrictions.golden.json` must not
move. If either moves, the transcription changed a string - fix the registry, not
the golden.

- [x] **Step 5: Compare the text surfaces against the Task 2 baseline**

```bash
zig build
diff <(./zig-out/bin/zts features) /tmp/features.v1.txt && echo "features text OK"
diff <(./zig-out/bin/zts restrictions) /tmp/restrictions.v1.txt && echo "restrictions text OK"
diff <(./zig-out/bin/zts restrictions --by proof) <(true) >/dev/null; \
  ./zig-out/bin/zts restrictions --by proof | head -5
```

Expected: both diffs empty. The third command is a smoke check that grouping still
renders (it has no baseline file; eyeball that it prints grouped rows).

- [x] **Step 6: Commit**

```bash
zig fmt packages/tools/src/json_diagnostics.zig
git add -A && git commit -m "refactor(features): project the v1 blocked table from the restriction registry"
```

---

### Task 4: the resolved module graph and `module_graph_hash`

**Files:**
- Create: `packages/tools/src/module_graph_record.zig`
- Modify: `packages/tools/src/zts_cli.zig` (re-export block)
- Test: in `module_graph_record.zig`

**Interfaces:**
- Consumes: `agent_identity.sourceDigest` / `canonicalRelPath` (Task 1),
  `zts.modules.resolver.resolve`, `zts.modules.file_resolver`, `zts.parser`,
  `zts.strip`, `zts.module_manifest.registryHashFromBindings`,
  `zts.builtin_modules.all`.
- Produces:

```zig
pub const ImportKind = enum { builtin, extension, relative, unresolved };
pub const ImportRecord = struct { specifier: []const u8, kind: ImportKind, target: []const u8 };
pub const ModuleRecord = struct { path: []const u8, source_digest: [64]u8, imports: []ImportRecord };
pub const Rejection = struct { specifier: []const u8, importer: []const u8, reason: []const u8 };
pub const GraphRecord = struct {
    modules: []ModuleRecord,        // ascending canonical-path order
    rejected: []Rejection,
    builtin_registry_hash: [64]u8,
    hash: [64]u8,
    pub fn deinit(self: *GraphRecord, allocator: std.mem.Allocator) void;
};
pub fn build(allocator, canonical_root: []const u8, entry_rel: []const u8) !GraphRecord;
pub fn contextFreeHash() [64]u8;
```

Task 5 calls `contextFreeHash()` for operations with no `file` input and `build`
for the rest; Task 8 serializes a `GraphRecord` as the `modules` payload.

**Why a new walker rather than `zts.modules.module_graph`.** Measured against
`packages/zts/src/modules/internal/module_graph.zig:150-215`: the existing graph
drops the import specifier text once it resolves a path, skips virtual and unknown
specifiers entirely (`.virtual, .unknown => {}`), keeps no digests, and records no
rejected candidate. Spec 4.8's `modules` operation requires all four. The existing
graph also owns runtime execution ordering; adding record-keeping to it would put
protocol concerns on the interpreter's path. The new walker reuses the same
resolution calls, so the two cannot disagree about what a specifier resolves to.

- [x] **Step 1: Write the failing tests**

```zig
const std = @import("std");

fn writeTmp(dir: std.testing.TmpDir, name: []const u8, bytes: []const u8) !void {
    try dir.dir.writeFile(.{ .sub_path = name, .data = bytes });
}

test "graph records imports in source order with kinds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(tmp, "util.ts", "export function two() { return 2; }\n");
    try writeTmp(tmp, "handler.ts",
        \\import { env } from "zttp:env";
        \\import { two } from "./util.ts";
        \\export function handler(req) { return Response.json({ n: two(), e: env("X") }); }
        \\
    );
    const a = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var graph = try build(a, root, "handler.ts");
    defer graph.deinit(a);

    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    // Ascending canonical-path order: handler.ts before util.ts.
    try std.testing.expectEqualStrings("handler.ts", graph.modules[0].path);
    try std.testing.expectEqualStrings("util.ts", graph.modules[1].path);

    const imports = graph.modules[0].imports;
    try std.testing.expectEqual(@as(usize, 2), imports.len);
    try std.testing.expectEqualStrings("zttp:env", imports[0].specifier);
    try std.testing.expectEqual(ImportKind.builtin, imports[0].kind);
    try std.testing.expectEqualStrings("./util.ts", imports[1].specifier);
    try std.testing.expectEqual(ImportKind.relative, imports[1].kind);
    try std.testing.expectEqualStrings("util.ts", imports[1].target);
}

test "graph hash is independent of which module was the entry" {
    // Same two files, entered from handler.ts and from util.ts. util.ts imports
    // nothing, so the graphs differ - this test pins the weaker property that
    // the digest is a function of the recorded set, not of traversal order.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(tmp, "a.ts", "import { b } from \"./b.ts\";\nexport const a = b;\n");
    try writeTmp(tmp, "b.ts", "import { a } from \"./a.ts\";\nexport const b = 1;\n");
    const alloc = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    var from_a = try build(alloc, root, "a.ts");
    defer from_a.deinit(alloc);
    var from_b = try build(alloc, root, "b.ts");
    defer from_b.deinit(alloc);

    try std.testing.expectEqualSlices(u8, &from_a.hash, &from_b.hash);
}

test "graph hash changes when a source byte changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(tmp, "h.ts", "export function handler(req) { return Response.json({ n: 1 }); }\n");
    const a = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var before = try build(a, root, "h.ts");
    const first = before.hash;
    before.deinit(a);

    try writeTmp(tmp, "h.ts", "export function handler(req) { return Response.json({ n: 2 }); }\n");
    var after = try build(a, root, "h.ts");
    defer after.deinit(a);

    try std.testing.expect(!std.mem.eql(u8, &first, &after.hash));
}

test "an import escaping the project root is rejected, not resolved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("app");
    try tmp.dir.writeFile(.{ .sub_path = "outside.ts", .data = "export const x = 1;\n" });
    try tmp.dir.writeFile(.{
        .sub_path = "app/handler.ts",
        .data = "import { x } from \"../outside.ts\";\nexport const y = x;\n",
    });
    const a = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(a, "app");
    defer a.free(base);

    var graph = try build(a, base, "handler.ts");
    defer graph.deinit(a);

    try std.testing.expectEqual(@as(usize, 1), graph.modules.len);
    try std.testing.expectEqual(@as(usize, 1), graph.rejected.len);
    try std.testing.expectEqualStrings("path_outside_project_root", graph.rejected[0].reason);
}

test "contextFreeHash is the builtin-only digest and is stable" {
    const h = contextFreeHash();
    try std.testing.expectEqualSlices(u8, &h, &contextFreeHash());
    // An empty module set must not collide with a real one-module graph.
    try std.testing.expect(!std.mem.eql(u8, &h, &[_]u8{'0'} ** 64));
}
```

- [x] **Step 2: Run, expect failure** (file missing).

Run: `zig build test-zts-cli -- --test-filter "graph"`

- [x] **Step 3: Implement the walker.** Structure:

```zig
//! The resolved module environment for one entry file, and its digest.
//!
//! Spec 4.8's `modules` operation returns the resolved relative graph with
//! source digests, the built-in registry, every resolution decision and rejected
//! candidate, and one digest over the whole environment. D3 §3 fixes that
//! digest's pre-image.
//!
//! This walker reuses `resolver.resolve` and `file_resolver.resolve`, the same
//! calls the runtime's `ModuleGraph` makes, so the two cannot disagree about
//! where a specifier points. It exists separately because `ModuleGraph` discards
//! the specifier text, skips virtual and unknown specifiers, and keeps no
//! digests - all four are protocol requirements and none is an execution
//! concern.

const std = @import("std");
const zts = @import("zts");
const agent_identity = @import("agent_identity.zig");
const resolver = zts.modules.resolver;
const file_resolver = zts.modules.file_resolver;
```

`build` walks breadth-first from the entry, and for each module:

1. Read the raw bytes (`zts.file_io.readFile`, 10 MiB cap, matching
   `canonicalize.collect`). `sourceDigest` hashes **these** bytes.
2. Strip TypeScript when the path ends `.ts`/`.tsx` (`zts.strip`), because the
   parser needs the stripped form - the runtime graph does the same at
   `module_graph.zig:117-133`.
3. Parse, enable JSX for `.jsx`/`.tsx`, and walk every `.import_decl` node in node
   order, which is source order. For each specifier:
   - `resolver.resolve(spec)` returns `.virtual` for `zttp:*` -> `kind = .builtin`,
     `target = spec`.
   - a specifier starting with `zttp-ext:` -> `kind = .extension`. Phase 1
     registers no extension manifests, so record it in `rejected` with reason
     `extension_manifest_unavailable` and keep the import record. Recorded as debt
     in Task 12.
   - `.file` -> resolve with `file_resolver.resolve` against the importer's
     directory, then `agent_identity.canonicalRelPath`. `error.PathOutsideProjectRoot`
     produces a `Rejection{ .reason = "path_outside_project_root" }` and no module.
     An unreadable target produces `.reason = "file_unreadable"`.
   - `.unknown` -> `kind = .unresolved`, and a `Rejection` with
     `.reason = "unknown_specifier"`.
4. Queue every newly resolved relative target, deduplicating on canonical path.
5. Sort `modules` by canonical path ascending (`std.mem.sortUnstable` with
   `std.mem.order(u8, a.path, b.path) == .lt`) and `rejected` by
   `(importer, specifier)`. D3 §3: ascending path order, not traversal order, so
   the digest does not depend on the entry file.

The digest, exactly D3 §3:

```zig
fn computeHash(modules: []const ModuleRecord, builtin_hash: [64]u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (modules) |m| {
        hasher.update(m.path);
        hasher.update("\x00");
        hasher.update(&m.source_digest);
        hasher.update("\x00");
        for (m.imports) |imp| {
            hasher.update(imp.specifier);
            hasher.update("\x00");
            hasher.update(@tagName(imp.kind));
            hasher.update("\x00");
            hasher.update(imp.target);
            hasher.update("\x00");
        }
        hasher.update("\x01");
    }
    hasher.update(&builtin_hash);
    hasher.update("\x01");
    // Extension manifests append here once they are authenticated; Phase 1
    // registers none, and an empty section is not the same pre-image as an
    // absent one, so the terminator above is unconditional.
    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

/// The digest of the module environment with no entry file: the built-in
/// registry alone. Operations that take no `file` bind this, so `expected`
/// still has something to compare and the envelope field is never empty.
pub fn contextFreeHash() [64]u8 {
    return computeHash(&.{}, zts.module_manifest.registryHashFromBindings(&zts.builtin_modules.all));
}
```

- [x] **Step 4: Run, expect PASS**

Run: `zig build test-zts-cli -- --test-filter "graph"`
Expected: PASS (5 tests).

- [x] **Step 5: Commit**

```bash
zig fmt packages/tools/src/module_graph_record.zig packages/tools/src/zts_cli.zig
git add -A && git commit -m "feat(agent): record the resolved module graph and compute module_graph_hash"
```

---

### Task 5: the v2 envelope, negotiation, and the error object

**Files:**
- Create: `packages/tools/src/agent_protocol.zig`
- Modify: `packages/tools/src/zts_cli.zig` (re-export block + one `commands` row)
- Modify: `packages/tools/src/edit_simulate.zig:425` (`fn readAllStdin` -> `pub fn readAllStdin`)
- Modify: `docs/cli.md` (one row in the Machine tools table)
- Test: in `agent_protocol.zig`

**Interfaces:**
- Consumes: Task 1 identity, Task 4 graph, `expert_meta.compiler_version` /
  `policy_version`, `rule_registry.policyHash()`.
- Produces:

```zig
pub const Operation = enum { meta, features, restrictions, describe_rule, modules,
                             check, canonicalize, simulate_edit, apply_repair,
                             normalize, verify };
pub const ErrorCode = enum { unknown_operation, malformed_request,
                             unsupported_schema_version, project_root_unresolvable,
                             path_outside_project_root, file_unreadable,
                             identity_mismatch, operation_not_implemented,
                             internal_error };
pub const OperationSpec = struct { op: Operation, status: enum { implemented, deferred },
                                   input_fields: []const []const u8,
                                   payload_fields: []const []const u8 };
pub const operations: []const OperationSpec;
pub fn handleRequest(allocator, request_json: []const u8, writer: *std.Io.Writer) !void;
pub fn runWithArgs(allocator, argv: []const []const u8) !void;
```

Tasks 6-11 add cases to the dispatch inside `handleRequest` and rows to
`operations`. `operations` is the single source for both dispatch and the `meta`
payload's operation schema - ground rule 3 in practice.

**Decision this task makes: `operation_not_implemented` joins the closed error
set.** D3 §6 lists eight codes and assumes every operation exists. Phase 1 ships
eight of eleven; `simulate_edit`, `apply_repair`, and `verify` arrive in Phase 6.
Returning `unknown_operation` for a named member of the spec's closed operation set
would be false, and a structured unsupported result is for unsupported *source*
constructs, not for an unbuilt operation. The ninth code is added here and D3 §6 is
amended in the same commit.

- [x] **Step 1: Write the failing tests**

```zig
const std = @import("std");

fn respond(allocator: std.mem.Allocator, request: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try handleRequest(allocator, request, &aw.writer);
    return aw.toOwnedSlice();
}

fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

test "meta response carries the full identity block" {
    const a = std.testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{}}
    );
    defer a.free(out);
    try std.testing.expectEqual(@as(u8, '\n'), out[out.len - 1]);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 2), obj.get("schema_version").?.integer);
    try std.testing.expectEqualStrings("meta", obj.get("operation").?.string);
    try std.testing.expectEqualStrings("zts-advanced-1", obj.get("profile_id").?.string);
    try std.testing.expectEqual(@as(usize, 64), obj.get("policy_hash").?.string.len);
    try std.testing.expectEqual(@as(usize, 64), obj.get("module_graph_hash").?.string.len);
    try std.testing.expect(obj.get("success").?.bool);
    try std.testing.expect(obj.get("payload").? == .object);
    try std.testing.expect(obj.get("diagnostics").? == .array);
    try std.testing.expect(obj.get("error") == null);
}

test "an unsupported schema version gets the frozen three-key response" {
    const a = std.testing.allocator;
    const out = try respond(a,
        \\{"schema_version":1,"operation":"meta","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 3), obj.count());
    try std.testing.expect(obj.get("schema_version_unsupported").?.bool);
    try std.testing.expectEqual(@as(usize, 1), obj.get("supported_schema_versions").?.array.items.len);
    try std.testing.expect(obj.get("compiler_version") != null);
    try std.testing.expect(obj.get("operation") == null);
}

test "an unknown operation is a protocol error, not a diagnostic" {
    const a = std.testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"transpile","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(!obj.get("success").?.bool);
    try std.testing.expectEqual(@as(usize, 0), obj.get("diagnostics").?.array.items.len);
    const err = obj.get("error").?.object;
    try std.testing.expectEqualStrings("unknown_operation", err.get("code").?.string);
    try std.testing.expectEqualStrings("operation", err.get("field").?.string);
}

test "a deferred operation says so instead of claiming it is unknown" {
    const a = std.testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"apply_repair","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("operation_not_implemented", err.get("code").?.string);
}

test "malformed input is a protocol error naming the offending field" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "not json at all",
        "[]",
        \\{"operation":"meta","project_root":".","input":{}}
        ,
        \\{"schema_version":2,"project_root":".","input":{}}
        ,
    }) |bad| {
        const out = try respond(a, bad);
        defer a.free(out);
        var parsed = try parse(a, out);
        defer parsed.deinit();
        const obj = parsed.value.object;
        const err = obj.get("error") orelse {
            std.debug.print("no error object for input: {s}\n", .{bad});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqualStrings("malformed_request", err.object.get("code").?.string);
    }
}

test "identical requests produce byte-identical responses" {
    const a = std.testing.allocator;
    const req =
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{}}
    ;
    const first = try respond(a, req);
    defer a.free(first);
    const second = try respond(a, req);
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
}
```

- [x] **Step 2: Run, expect failure** (file missing).

Run: `zig build test-zts-cli -- --test-filter "schema version"`

- [x] **Step 3: Implement the envelope**

```zig
//! `zts agent --stdin-json`: the version-2 agent protocol transport.
//!
//! One request object in, one response object out (spec 4.8). The v1 commands
//! stay exactly as they are; nothing here edits a v1 emitter. Every byte on this
//! wire is snake_case and written through `std.json.Stringify`.

const std = @import("std");
const zts = @import("zts");
const agent_identity = @import("agent_identity.zig");
const module_graph_record = @import("module_graph_record.zig");
const expert_meta = @import("expert_meta.zig");
const rule_registry = zts.rule_registry;

pub const Operation = enum {
    meta, features, restrictions, describe_rule, modules,
    check, canonicalize, simulate_edit, apply_repair, normalize, verify,
};

/// Closed set, published in `meta`. D3 §6 lists eight; `operation_not_implemented`
/// is the ninth, added because Phase 1 serves eight of the spec's eleven
/// operations and calling a named member of the closed operation set "unknown"
/// would be false.
pub const ErrorCode = enum {
    unknown_operation,
    malformed_request,
    unsupported_schema_version,
    project_root_unresolvable,
    path_outside_project_root,
    file_unreadable,
    identity_mismatch,
    operation_not_implemented,
    internal_error,
};

pub const Status = enum { implemented, deferred };

pub const OperationSpec = struct {
    op: Operation,
    status: Status,
    input_fields: []const []const u8,
    payload_fields: []const []const u8,
    /// Set for `deferred`: which phase builds it, so `meta` says when rather
    /// than only that it is missing.
    deferred_note: ?[]const u8 = null,
};

/// The dispatch table and the `meta.payload.operations` source, one table. A new
/// operation that is not listed here cannot be dispatched, and one listed here
/// cannot be omitted from `meta`.
pub const operations = [_]OperationSpec{
    .{ .op = .meta, .status = .implemented, .input_fields = &.{}, .payload_fields = &.{
        "compiler_version", "profile_id", "policy_version", "policy_hash",
        "builtin_registry_hash", "restriction_matrix_hash", "idiom_table_hash",
        "operations", "severities", "idioms", "restrictions", "limits",
        "module_catalog", "deferred_sections",
    } },
    // ... one row per operation; Tasks 7-10 flip rows to `implemented` as they land.
    .{ .op = .apply_repair, .status = .deferred, .input_fields = &.{ "file", "repairs" }, .payload_fields = &.{}, .deferred_note = "phase 6: needs the equivalence-validator registry" },
};
```

The request side:

```zig
const Request = struct {
    schema_version: i64,
    operation: []const u8,
    project_root: []const u8,
    input: std.json.Value,
    expected: ?std.json.Value,
};

fn parseRequest(root: std.json.Value) ?Request { ... }  // null => malformed
```

`handleRequest` runs in this fixed order, and every failure below writes a
response and returns without an error:

1. Parse JSON. Not an object -> `malformed_request`, field `null`.
2. Read `schema_version`. Missing or not an integer -> `malformed_request`, field
   `schema_version`. Present but not 2 -> the frozen negotiation response, which
   is written by its own function and shares no code with the envelope so a later
   envelope change cannot move it:

```zig
/// Frozen across all present and future schema versions (spec 4.8). Three keys,
/// no envelope, no diagnostics. A v3 binary must return exactly this to a v1
/// client, so this function takes no envelope state and never gains a field.
fn writeNegotiation(json: *std.json.Stringify) !void {
    try json.beginObject();
    try json.objectField("schema_version_unsupported");
    try json.write(true);
    try json.objectField("supported_schema_versions");
    try json.beginArray();
    for (agent_identity.supported_schema_versions) |v| try json.write(v);
    try json.endArray();
    try json.objectField("compiler_version");
    try json.write(expert_meta.compiler_version);
    try json.endObject();
}
```

3. Read `operation`. Missing/not a string -> `malformed_request`. Not a member of
   `Operation` -> `unknown_operation`, field `operation`. A member whose spec row
   is `.deferred` -> `operation_not_implemented`, field `operation`.
4. Read `project_root` (missing -> `malformed_request`) and canonicalize it;
   `error.ProjectRootUnresolvable` -> that code, field `project_root`.
5. Compute identity: `policy_hash` from `rule_registry.policyHash()`,
   `module_graph_hash` from `module_graph_record.contextFreeHash()` for an
   operation whose `input_fields` do not include `"file"`, else from
   `module_graph_record.build`. A build failure maps to `file_unreadable` or
   `path_outside_project_root`.
6. The `expected` guard (Task 6).
7. Dispatch. The operation writes its payload object and its diagnostics array
   into two allocating buffers and returns `success`.
8. Write the envelope in spec order:

```zig
fn writeEnvelope(
    json: *std.json.Stringify,
    op_name: []const u8,
    identity: Identity,
    success: bool,
    payload_json: []const u8,     // a serialized object, "{}" when empty
    diagnostics_json: []const u8, // a serialized array, "[]" when empty
    err: ?ProtocolError,
) !void {
    try json.beginObject();
    try json.objectField("schema_version");
    try json.write(agent_identity.schema_version);
    try json.objectField("operation");
    try json.write(op_name);
    try json.objectField("profile_id");
    try json.write(agent_identity.profile_id);
    try json.objectField("compiler_version");
    try json.write(expert_meta.compiler_version);
    try json.objectField("policy_version");
    try json.write(expert_meta.policy_version);
    try json.objectField("policy_hash");
    try json.write(&identity.policy_hash);
    try json.objectField("module_graph_hash");
    try json.write(&identity.module_graph_hash);
    try json.objectField("success");
    try json.write(success);
    try json.objectField("payload");
    try json.beginWriteRaw();
    try json.writer.writeAll(payload_json);
    json.endWriteRaw();
    try json.objectField("diagnostics");
    try json.beginWriteRaw();
    try json.writer.writeAll(diagnostics_json);
    json.endWriteRaw();
    if (err) |e| {
        try json.objectField("error");
        try json.beginObject();
        try json.objectField("code");
        try json.write(@tagName(e.code));
        try json.objectField("message");
        try json.write(e.message);
        try json.objectField("field");
        if (e.field) |f| try json.write(f) else try json.write(null);
        try json.endObject();
    }
    try json.endObject();
    try json.writer.writeByte('\n');
}
```

An error response still carries the identity block: a client that hit
`identity_mismatch` needs the current values to recover, and a client that hit
`unknown_operation` needs to know which binary answered.

- [x] **Step 4: Implement the `meta` payload minimally** - just enough for the
tests above to pass: `compiler_version`, `profile_id`, `policy_version`,
`policy_hash`, `operations` (from the table), `deferred_sections`. Task 11 fills
the rest. Do not write a placeholder for anything else.

- [x] **Step 5: Wire the CLI**

```zig
pub fn runWithArgs(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var stdin_json = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--stdin-json")) {
            stdin_json = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else {
            return error.InvalidArgument;
        }
    }
    if (!stdin_json) {
        printHelp();
        return error.InvalidArgument;
    }

    const request = try edit_simulate.readAllStdin(allocator);
    defer allocator.free(request);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try handleRequest(allocator, request, &aw.writer);

    const bytes = aw.writer.buffered();
    if (bytes.len > 0) _ = std.c.write(std.c.STDOUT_FILENO, bytes.ptr, bytes.len);
}
```

Register it in `zts_cli.zig`'s `commands` table, after `describe-rule`:

```zig
.{ .name = "agent", .run = agent_protocol.runWithArgs, .category = .machine, .args = "--stdin-json", .blurb = "Version-2 agent protocol over stdin/stdout", .usage = "agent --stdin-json" },
```

Change `fn readAllStdin` to `pub fn readAllStdin` in `edit_simulate.zig` rather
than copying the 16-line reader; it already caps at `max_stdin_json_bytes` and
handles `WouldBlock`.

- [x] **Step 6: Run, expect PASS**, then the whole tools suite:

Run: `zig build test-zts-cli` then `zig build test-cli`
Expected: PASS. `zig build test-expert-golden` must stay green - no v1 byte moved.

- [x] **Step 7: Smoke it**

```bash
zig build
echo '{"schema_version":2,"operation":"meta","project_root":".","input":{}}' \
  | ./zig-out/bin/zts agent --stdin-json | python3 -m json.tool | head -20
echo '{"schema_version":1,"operation":"meta","project_root":".","input":{}}' \
  | ./zig-out/bin/zts agent --stdin-json
```

Expected: a full envelope, then exactly
`{"schema_version_unsupported":true,"supported_schema_versions":[2],"compiler_version":"0.18.0"}`.

- [x] **Step 8: Document.** Add one row to the Machine tools table in
`docs/cli.md` and a sentence that `agent` is the only version-2 surface, with the
v1 commands named as legacy per spec 4.8.

- [x] **Step 9: Commit**

```bash
zig fmt packages/tools/src/agent_protocol.zig packages/tools/src/zts_cli.zig packages/tools/src/edit_simulate.zig
git add -A && git commit -m "feat(agent): v2 envelope, frozen version negotiation, and the protocol error object"
```

---

### Task 6: the uniform `expected` staleness guard

**Files:**
- Modify: `packages/tools/src/agent_protocol.zig`
- Test: same file

**Interfaces:**
- Consumes: the `Identity` struct from Task 5.
- Produces: `fn checkExpected(expected: ?std.json.Value, identity: Identity) ?ProtocolError`.
  Runs for every operation, before any work, after identity computation.

- [x] **Step 1: Write the failing tests**

```zig
test "a matching expected block passes the guard" {
    const a = std.testing.allocator;
    const hash = zts.rule_registry.policyHash();
    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"meta","project_root":".","input":{{}},
        \\ "expected":{{"profile_id":"zts-advanced-1","policy_hash":"{s}"}}}}
    , .{hash});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("success").?.bool);
}

test "a stale policy_hash fails with both values named" {
    const a = std.testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{},
        \\ "expected":{"policy_hash":"0000000000000000000000000000000000000000000000000000000000000000"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(!obj.get("success").?.bool);
    const err = obj.get("error").?.object;
    try std.testing.expectEqualStrings("identity_mismatch", err.get("code").?.string);
    try std.testing.expectEqualStrings("expected.policy_hash", err.get("field").?.string);
    // The message names the expected and the actual value, so a client can
    // re-bind without a second round trip.
    try std.testing.expect(std.mem.indexOf(u8, err.get("message").?.string, "0000000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.get("message").?.string, &zts.rule_registry.policyHash()) != null);
}

test "a stale profile_id fails the same way" {
    const a = std.testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{},
        \\ "expected":{"profile_id":"zts-1"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("identity_mismatch", err.get("code").?.string);
    try std.testing.expectEqualStrings("expected.profile_id", err.get("field").?.string);
}

test "an omitted expected block skips the guard entirely" {
    const a = std.testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{},"expected":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("success").?.bool);
}

test "an unknown key inside expected is malformed, not ignored" {
    // Silently ignoring a misspelled guard field would report success for an
    // unguarded request - the exact failure the guard exists to prevent.
    const a = std.testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{},
        \\ "expected":{"policy_hashh":"x"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("malformed_request", err.get("code").?.string);
    try std.testing.expectEqualStrings("expected.policy_hashh", err.get("field").?.string);
}
```

- [x] **Step 2: Run, expect FAIL** (guard absent, every request succeeds).

Run: `zig build test-zts-cli -- --test-filter "expected"`

- [x] **Step 3: Implement**

```zig
/// Spec 4.8: one rule for every operation. A supplied field that does not match
/// the recomputed identity fails the request naming the field and both values.
/// An absent block skips the guard. The check runs before any work, so a stale
/// `apply_repair` writes nothing when that operation lands in phase 6.
fn checkExpected(
    allocator: std.mem.Allocator,
    expected: ?std.json.Value,
    identity: Identity,
) !?ProtocolError {
    const obj = switch (expected orelse return null) {
        .object => |o| o,
        else => return ProtocolError.malformed(null, "expected", "expected must be an object"),
    };
    var it = obj.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const actual: []const u8 =
            if (std.mem.eql(u8, key, "profile_id")) agent_identity.profile_id
            else if (std.mem.eql(u8, key, "policy_hash")) &identity.policy_hash
            else if (std.mem.eql(u8, key, "module_graph_hash")) &identity.module_graph_hash
            else return try ProtocolError.malformedField(allocator, key);
        if (kv.value_ptr.* != .string) return try ProtocolError.malformedField(allocator, key);
        const supplied = kv.value_ptr.string;
        if (!std.mem.eql(u8, supplied, actual)) {
            return try ProtocolError.mismatch(allocator, key, supplied, actual);
        }
    }
    return null;
}
```

`ProtocolError.mismatch` formats
`"expected.<field> is stale: request said <supplied>, this compiler reports <actual>"`
and sets `.field = "expected.<field>"`. The message allocation is owned by the
response arena, which `handleRequest` frees after writing.

Note the iteration order: `std.json.ObjectMap` is an `ArrayHashMap`, so iteration
follows insertion order, which is request order - deterministic for a given
request. Two mismatched fields report the first in request order.

- [x] **Step 4: Run, expect PASS**

Run: `zig build test-zts-cli -- --test-filter "expected"`
Expected: PASS (5 tests).

- [x] **Step 5: Commit**

```bash
zig fmt packages/tools/src/agent_protocol.zig
git add -A && git commit -m "feat(agent): uniform expected-identity staleness guard"
```

---

### Task 7: `features`, `restrictions`, and `describe_rule` payloads

**Files:**
- Modify: `packages/tools/src/agent_protocol.zig`
- Test: same file

**Interfaces:**
- Consumes: `restriction_registry.entries` (Task 2), `rule_registry.all_rules`,
  `strict_checker.Severity`.
- Produces: three payload writers and three `operations` rows flipped to
  `.implemented`. Payload shapes per D3 §6:
  - `features` -> `{ "features": [{ "id", "category", "status" }] }`
  - `restrictions` -> `{ "restrictions": [{ "id", "feature", "boundary", "nature", "note", "alternative", "failure_class", "proof_unlocked", "enforced_by", "unenforced_note" }] }`
  - `describe_rule` -> `{ "rules": [{ "name", "code", "category", "description", "example", "help", "repair_intent", "severity" }] }`

- [x] **Step 1: Write the failing tests**

```zig
test "restrictions payload publishes every matrix row, not only the v1 set" {
    const a = std.testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"restrictions","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const rows = parsed.value.object.get("payload").?.object.get("restrictions").?.array;
    try std.testing.expectEqual(zts.restriction_registry.entries.len, rows.items.len);
    const first = rows.items[0].object;
    try std.testing.expect(std.mem.startsWith(u8, first.get("id").?.string, "restriction."));
    try std.testing.expect(first.get("nature") != null);
    try std.testing.expect(first.get("enforced_by").? == .array);
}

test "describe_rule with no filter returns every registry rule with a severity" {
    const a = std.testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"describe_rule","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const rules = parsed.value.object.get("payload").?.object.get("rules").?.array;
    try std.testing.expectEqual(zts.rule_registry.all_rules.len, rules.items.len);
    for (rules.items) |r| {
        const sev = r.object.get("severity").?.string;
        // Closed set (spec 4.8). A rule declaring anything else is a bug in the
        // severity projection, not a new severity.
        const ok = std.mem.eql(u8, sev, "error") or std.mem.eql(u8, sev, "warning") or
            std.mem.eql(u8, sev, "advisory");
        try std.testing.expect(ok);
    }
}

test "describe_rule with a rule filter returns exactly that rule" {
    const a = std.testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"describe_rule","project_root":".","input":{"rule":"ZTS303"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const rules = parsed.value.object.get("payload").?.object.get("rules").?.array;
    try std.testing.expectEqual(@as(usize, 1), rules.items.len);
    try std.testing.expectEqualStrings("ZTS303", rules.items[0].object.get("code").?.string);
}

test "describe_rule with an unknown rule succeeds with an empty list" {
    // Not an error: the closed operation set answers "no such rule" as data.
    const a = std.testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"describe_rule","project_root":".","input":{"rule":"ZTS999"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("success").?.bool);
    try std.testing.expectEqual(@as(usize, 0),
        parsed.value.object.get("payload").?.object.get("rules").?.array.items.len);
}

test "features payload ids match the v1 feature names" {
    const a = std.testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"features","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const items = parsed.value.object.get("payload").?.object.get("features").?.array;
    try std.testing.expect(items.items.len >= 22);
    for (items.items) |f| {
        const status = f.object.get("status").?.string;
        const ok = std.mem.eql(u8, status, "allowed") or std.mem.eql(u8, status, "blocked");
        try std.testing.expect(ok);
    }
}
```

- [x] **Step 2: Run, expect FAIL** (operations still `deferred`).

Run: `zig build test-zts-cli -- --test-filter "payload"`

- [x] **Step 3: Implement the three writers.** Each takes
`(*std.json.Stringify, input: std.json.Value)` and writes one object.

**Severity projection.** `rule_registry.RuleEntry` carries no severity field, and
spec 4.8 requires every rule to declare one. Phase 1 derives it rather than adding
a field, because adding one shifts `policy_hash` and every golden:

```zig
/// Spec 4.8 requires each rule to publish the severity it emits. The registry
/// carries no severity column, so it is derived from the category: `.property`
/// and `.flow` rules report hazards the profile still admits, every other
/// category rejects the program. Advisory is not yet reachable from a rule -
/// the idiom channel that emits it is phase 6 - and the closed set is published
/// in full by `meta.payload.severities` regardless.
fn ruleSeverity(entry: *const rule_registry.RuleEntry) []const u8 {
    return switch (entry.category) {
        .verifier, .policy => "error",
        .property, .flow => "warning",
    };
}
```

Verify this against reality before committing it:

```bash
./zig-out/bin/zts check packages/tools/tests/fixtures/contract/modules_all.ts --json \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
for x in d.get('diagnostics', []):
    print(x['code'], x['severity'])
" | sort -u
```

If any observed pair contradicts the mapping, fix the mapping to match the
observed emission and note the exception inline - the compiler's behavior is the
truth, not the category.

- [x] **Step 4: Run, expect PASS**

Run: `zig build test-zts-cli -- --test-filter "payload"`
Expected: PASS (5 tests).

- [x] **Step 5: Commit**

```bash
zig fmt packages/tools/src/agent_protocol.zig
git add -A && git commit -m "feat(agent): features, restrictions, and describe_rule payloads"
```

---

### Task 8: the `modules` operation

**Files:**
- Modify: `packages/tools/src/agent_protocol.zig`
- Test: same file

**Interfaces:**
- Consumes: `module_graph_record.build` (Task 4).
- Produces: payload
  `{ "graph": [{ "path", "source_digest", "imports": [{ "specifier", "kind", "target" }] }], "builtins": [{ "specifier", "exports": [...] }], "extensions": [], "rejected": [{ "specifier", "importer", "reason" }], "module_graph_hash" }`.
  The envelope's `module_graph_hash` and the payload's are the same value,
  computed once.

- [x] **Step 1: Write the failing test**

```zig
test "modules returns the resolved graph and binds the same hash twice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "util.ts", .data = "export const two = 2;\n" });
    try tmp.dir.writeFile(.{ .sub_path = "handler.ts", .data =
        \\import { env } from "zttp:env";
        \\import { two } from "./util.ts";
        \\export function handler(req) { return Response.json({ two, e: env("X") }); }
        \\
    });
    const a = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"handler.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("success").?.bool);
    const payload = obj.get("payload").?.object;
    try std.testing.expectEqualStrings(
        obj.get("module_graph_hash").?.string,
        payload.get("module_graph_hash").?.string,
    );
    try std.testing.expectEqual(@as(usize, 2), payload.get("graph").?.array.items.len);
    try std.testing.expect(payload.get("builtins").?.array.items.len > 0);
    try std.testing.expectEqual(@as(usize, 0), payload.get("rejected").?.array.items.len);
}

test "modules on a file outside the project root is a protocol error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("app");
    const a = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(a, "app");
    defer a.free(root);
    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"../escape.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("path_outside_project_root", err.get("code").?.string);
    try std.testing.expectEqualStrings("input.file", err.get("field").?.string);
}

test "modules on a missing file reports file_unreadable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"nope.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("file_unreadable",
        parsed.value.object.get("error").?.object.get("code").?.string);
}
```

- [x] **Step 2: Run, expect FAIL.**

Run: `zig build test-zts-cli -- --test-filter "modules"`

- [x] **Step 3: Implement.** `builtins` comes from `zts.builtin_modules.all`:
specifier plus each export's `name` and `@tagName(effect)`. `extensions` is an
empty array in Phase 1 with the reason recorded in `meta.deferred_sections` (Task
11), not with a prose note in the payload.

- [x] **Step 4: Run, expect PASS.** `zig build test-zts-cli -- --test-filter "modules"`

- [x] **Step 5: Commit**

```bash
zig fmt packages/tools/src/agent_protocol.zig
git add -A && git commit -m "feat(agent): modules operation over the resolved graph"
```

---

### Task 9: the `check` operation

**Files:**
- Modify: `packages/tools/src/agent_protocol.zig`
- Test: same file

**Interfaces:**
- Consumes: `precompile.runCheckOnlyWithOptions` (returns
  `precompile_check.CheckResult`), `rule_registry.findByCode`,
  `agent_identity.sourceDigest`.
- Produces: payload
  `{ "file", "source_digest", "counts": { "errors", "warnings" }, "properties"?, "paths": { "enumerated", "exhaustive", "coverage_note" }, "max_io_depth", "contract_available" }`
  and a `diagnostics` array of

```
{ "code", "rule_id", "severity", "message", "file", "source_digest",
  "line", "column", "byte_offset", "suggestion", "repair_available" }
```

**Two decisions, both recorded at Task 12:**

1. **No `span`, and `repair_available` is uniformly false.** `JsonDiagnostic`
   (`json_diagnostics.zig:30-47`) carries `line` and `column` and no byte range,
   so an exact half-open span cannot be produced without threading offsets through
   every producer. Phase 1 publishes `byte_offset` - the exact start, computed from
   line and column against the raw bytes - and omits `span` rather than inventing
   an end. `repair_available` is false everywhere because spec 4.8 permits an
   exact repair only when a registered equivalence validator exists, and the
   validator registry is Phase 6. Both are debts, not approximations.
2. **The contract body stays a v1 surface.** `writeContractJson` emits mixed-case
   keys (`proofCapsules` beside `env_vars`) and is several hundred lines. Phase 1
   publishes `contract_available: true` and leaves the body to
   `zts check --json --contract`; a snake_case contract serializer lands with
   `verify` in Phase 6.

- [x] **Step 1: Write the failing tests**

```zig
test "check on a clean handler succeeds with no diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "h.ts", .data =
        \\export function handler(req) { return Response.json({ ok: true }); }
        \\
    });
    const a = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"check","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("success").?.bool);
    try std.testing.expectEqual(@as(usize, 0), obj.get("diagnostics").?.array.items.len);
    const payload = obj.get("payload").?.object;
    try std.testing.expectEqualStrings("h.ts", payload.get("file").?.string);
    try std.testing.expectEqual(@as(usize, 64), payload.get("source_digest").?.string.len);
}

test "check on a rejected handler reports success false with bound diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A chained ternary: ZTS621, an error-severity canonical-profile rule
    // (phase 0, task 3).
    try tmp.dir.writeFile(.{ .sub_path = "h.ts", .data =
        \\export function handler(req) {
        \\  const n = req.method === "GET" ? 1 : req.method === "POST" ? 2 : 3;
        \\  return Response.json({ n });
        \\}
        \\
    });
    const a = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"check","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(!obj.get("success").?.bool);
    const diags = obj.get("diagnostics").?.array;
    try std.testing.expect(diags.items.len >= 1);
    const d = diags.items[0].object;
    try std.testing.expectEqualStrings("ZTS621", d.get("code").?.string);
    try std.testing.expectEqualStrings("error", d.get("severity").?.string);
    try std.testing.expectEqual(@as(usize, 64), d.get("source_digest").?.string.len);
    try std.testing.expect(d.get("byte_offset").?.integer > 0);
    try std.testing.expect(!d.get("repair_available").?.bool);
    // rule_id resolves through the registry; null only for the ZTS0xx/ZTS2xx
    // bands that live outside it.
    try std.testing.expectEqualStrings("canonical_ternary_chain", d.get("rule_id").?.string);
}

test "success is exactly no error diagnostic, not no diagnostic" {
    // A warning-severity diagnostic must leave success true (spec 4.8 line 610).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "h.ts", .data = warning_only_handler });
    // ... assert success == true and at least one "warning" diagnostic.
}
```

For the third test, pick the vehicle by measurement, not by guess:

```bash
for f in packages/tools/tests/fixtures/contract/*.ts; do
  echo "== $f"
  ./zig-out/bin/zts check "$f" --json | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(sorted({x['severity'] for x in d.get('diagnostics',[])}))
"
done
```

Use the smallest fixture whose severity set is exactly `['warning']` as
`warning_only_handler`.

- [x] **Step 2: Run, expect FAIL.**

Run: `zig build test-zts-cli -- --test-filter "check on"`

- [x] **Step 3: Implement.** The operation:

1. Resolves `input.file` through `canonicalRelPath`; reads the bytes once and
   keeps them for both `sourceDigest` and `byteOffsetOf`.
2. Calls `precompile.runCheckOnlyWithOptions(allocator, abs_path, .{ .json_mode = true, .sql_schema_path = null, .system_path = null })`.
   `error.MissingSqlSchema` becomes a diagnostic-free response with
   `success: false` and the ZTS700 diagnostic the v1 path emits, so the two
   surfaces agree on that case.
3. Maps every `result.json_diagnostics` item. `rule_id` is
   `rule_registry.findByCode(code)` name, or null.
4. `success = result.totalErrors() == 0`. Warnings never flip it.

The offset helper, next to the mapper:

```zig
/// Byte offset of a 1-based line and column in `source`. Exact for the reported
/// position; the end of the range is not published because no producer computes
/// one (see the task's decision 1).
fn byteOffsetOf(source: []const u8, line: u32, column: u32) usize {
    var current_line: u32 = 1;
    var idx: usize = 0;
    while (idx < source.len and current_line < line) : (idx += 1) {
        if (source[idx] == '\n') current_line += 1;
    }
    return @min(idx + @as(usize, if (column > 0) column - 1 else 0), source.len);
}
```

- [x] **Step 4: Run, expect PASS**, then the full suite:

Run: `zig build test-zts-cli` then `zig build test`
Expected: PASS.

- [x] **Step 5: Commit**

```bash
zig fmt packages/tools/src/agent_protocol.zig
git add -A && git commit -m "feat(agent): check operation with digest-bound diagnostics"
```

---

### Task 10: `canonicalize` and `normalize`

**Files:**
- Modify: `packages/tools/src/agent_protocol.zig`
- Test: same file

**Interfaces:**
- Consumes: `canonicalize.collect`, `canonicalize.simulateRefactors`,
  `canonicalize.normalize`, `idiom_registry.findByRewriteRule`.
- Produces:
  - `canonicalize` payload
    `{ "file", "source_digest", "candidates": [{ "kind", "grade", "idiom_id", "line", "column", "message", "original", "replacement" }], "simulation"? }`
  - `normalize` payload
    `{ "file", "source_digest", "converged", "fully_canonical", "iterations", "residual", "rewrite_trace": [{ "intent", "idiom_id" }], "canonical_source", "residual_diagnostics": [...] }`

**Decision: every candidate's `grade` is `"proposed_refactor"`.** Spec 4.8: "Until
a rewrite has a registered equivalence validator, `canonicalize` and `normalize`
MUST report it as a proposed refactor, not a mechanical repair." No validator
registry exists before Phase 6, so the grade is constant, and it is written from
one named constant so Phase 6 changes one line rather than hunting for literals.

**`original` is serialized.** D3 §5 records that `original_line` is dropped at the
v1 JSON boundary (`canonicalize.zig:2581-2610`), which leaves a client unable to
re-validate staleness. The v2 payload publishes it. The v1 emitter is not touched.

- [x] **Step 1: Write the failing tests**

```zig
test "canonicalize candidates carry a grade and their idiom where wired" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ZTS619: for...of over items.entries() with an unread index. Phase 0 wired
    // this rewrite to idiom.element-iteration.
    try tmp.dir.writeFile(.{ .sub_path = "h.ts", .data =
        \\export function handler(req) {
        \\  const items = ["a", "b"];
        \\  const out = [];
        \\  for (const [i, item] of items.entries()) { out.push(item); }
        \\  return Response.json({ out });
        \\}
        \\
    });
    // ... assert candidates.len >= 1, every candidate grade == "proposed_refactor",
    // and that the ZTS619 candidate's idiom_id == "idiom.element-iteration".
}

test "normalize reports the fixed point and never writes" {
    // Same file; assert converged/fully_canonical/iterations/canonical_source,
    // then re-read the file from disk and assert the bytes are unchanged.
}

test "normalize with write true is refused, not silently ignored" {
    const a = std.testing.allocator;
    // ... input {"file":"h.ts","write":true}
    // expect error.code == "operation_not_implemented" and field "input.write";
    // the message names apply_repair as the channel that writes.
}

test "canonicalize simulation runs only when asked" {
    // input {"file":"h.ts"} -> payload has no "simulation" key
    // input {"file":"h.ts","simulate":true} -> payload.simulation has
    // ok / total / new_count / preexisting_count
}
```

Fill the two elided bodies from the harness the first test establishes; the
assertions listed are the deliverable.

- [x] **Step 2: Run, expect FAIL.**

Run: `zig build test-zts-cli -- --test-filter "canonicalize"`

- [x] **Step 3: Implement.** `Refactor.kind` is a string today
(`canonicalize.zig:13-20`), so `kind` is published verbatim and `idiom_id` is
resolved through `idiom_registry.findByRewriteRule` on the `RepairIntent` tag name
where one exists, null otherwise - the Phase 0 back-reference direction, unchanged.
`normalize`'s `rewrite_trace` is a list of `RepairIntent` tag names, each paired
with its idiom id when the registry has one.

`write: true` returns `operation_not_implemented` with field `input.write` and the
message "normalize does not write in schema version 2; apply the returned
canonical_source through apply_repair (phase 6)".

- [x] **Step 4: Run, expect PASS**, then the canonicalize suite:

Run: `zig build test-zts-cli -- --test-filter "canonicalize"` then
`zig build test-canonicalize`
Expected: PASS, and the idempotence gate untouched.

- [x] **Step 5: Commit**

```bash
zig fmt packages/tools/src/agent_protocol.zig
git add -A && git commit -m "feat(agent): canonicalize and normalize operations with proposed-refactor grades"
```

---

### Task 11: the `meta` payload, registry-generated

**Files:**
- Modify: `packages/tools/src/agent_protocol.zig`
- Modify: `packages/zts/src/idiom_registry.zig` (add `tableHash()`)
- Test: both files

**Interfaces:**
- Consumes: `restriction_registry.matrixHash()` (Task 2),
  `idiom_registry.tableHash()` (this task), `rule_registry.policyHash()`,
  `module_manifest.registryHashFromBindings`, `strict_checker.Severity`,
  `canonicalize.max_normalize_iterations`, `edit_simulate.max_stdin_json_bytes`.
- Produces the payload named in Task 5's `operations` row, plus
  `deferred_sections`.

**What is deliberately absent.** Spec 4.8 also requires `grammar`, `examples`,
`ambient_names`, `validators`, `type_serialization`, and `decisions`. None has a
registry today: the grammar lives in spec prose, the validator taxonomy is D3 §4
and lands in Phase 6, the canonical type serialization is D1 and lands in Phase 2,
and no decision-kind registry exists anywhere in the tree. Ground rule 3 forbids
hand-writing them, so each is listed in `deferred_sections` with the phase that
builds it. A client reads one machine-readable list instead of discovering
absence key by key.

- [x] **Step 1: Write the failing tests**

```zig
test "meta publishes every operation in the dispatch table" {
    const a = std.testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;
    const ops = payload.get("operations").?.array;
    try std.testing.expectEqual(operations.len, ops.items.len);
    // Every enum member appears exactly once: the table cannot drift from the
    // operation set the dispatcher accepts.
    inline for (@typeInfo(Operation).@"enum".fields) |field| {
        var seen: usize = 0;
        for (ops.items) |o| {
            if (std.mem.eql(u8, o.object.get("id").?.string, field.name)) seen += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), seen);
    }
}

test "meta publishes the closed severity set and the success rule" {
    // severities == ["error","warning","advisory"], derived from
    // strict_checker.Severity, plus success_rule naming the error-only rule.
}

test "meta publishes the three registry hashes" {
    // policy_hash, restriction_matrix_hash, idiom_table_hash: each 64 hex chars,
    // and policy_hash equals rule_registry.policyHash().
}

test "meta lists the deferred sections rather than stubbing them" {
    // deferred_sections contains grammar, examples, ambient_names, validators,
    // type_serialization, decisions - each with a phase note - and the payload
    // has no key by any of those names.
}

test "idiom tableHash is stable" {
    const h = tableHash();
    try std.testing.expectEqual(@as(usize, 64), h.len);
    try std.testing.expectEqualSlices(u8, &h, &tableHash());
}
```

- [x] **Step 2: Run, expect FAIL.**

Run: `zig build test-zts-cli -- --test-filter "meta publishes"` and
`zig build test-zts -- --test-filter "tableHash"`

- [x] **Step 3: Add `tableHash` to `idiom_registry.zig`**, pre-image per D3 §3:
`id \0 operation \0 idiomatic \0 superseded \0 precondition \0 rewrite_rule-or-"-" \x01`,
cached the same way `rule_registry.policyHash` caches.

- [x] **Step 4: Implement the payload.** `limits` carries only constants that
exist in the tree - no invented numbers:

```zig
try json.objectField("limits");
try json.beginObject();
try json.objectField("normalize_iterations");
try json.write(canonicalize.max_normalize_iterations);   // 64
try json.objectField("request_bytes");
try json.write(edit_simulate.max_stdin_json_bytes);      // 20 MiB
try json.objectField("source_bytes");
try json.write(@as(usize, 10 * 1024 * 1024));            // matches canonicalize.collect
try json.endObject();
```

The repair-iteration and tool-call budget spec 4.8 asks for is a loop policy no
code implements; it goes in `deferred_sections`, not in `limits` as a guess.

`module_catalog` walks `builtin_modules.all`: specifier, module name, required
capabilities, and each export's name and effect - all from the bindings, which are
already the generated source for `packages/modules/module-specs/`.

- [x] **Step 5: Run, expect PASS**

Run: `zig build test-zts-cli -- --test-filter "meta"` then `zig build test-zts -- --test-filter "tableHash"`

- [x] **Step 6: Commit**

```bash
zig fmt packages/tools/src/agent_protocol.zig packages/zts/src/idiom_registry.zig
git add -A && git commit -m "feat(agent): registry-generated meta payload with explicit deferred sections"
```

---

### Task 12: phase gate

**Files:**
- Create: `scripts/check-agent-determinism.sh`
- Create: `docs/internals/agent-protocol-v2.md`
- Modify: `scripts/verify.sh` (one step)
- Modify: `docs/plans/2026-07-30-012-zts-advanced-rev4-master-plan.md` (decision log)
- Modify: `docs/plans/2026-07-30-016-d3-canonical-form-wire-design.md` (§6 error-code set)
- Modify: `docs/internals/zts-expert-contract.md` (one paragraph: v1 is legacy)

- [x] **Step 1: The determinism gate**

```bash
#!/usr/bin/env bash
# scripts/check-agent-determinism.sh
#
# Spec 4.8: the agent transport emits only the response JSON on stdout, and
# array order is deterministic for identical authenticated inputs. Two identical
# requests must produce byte-identical stdout, and stdout must parse as exactly
# one JSON object.

set -euo pipefail
cd "$(dirname "$0")/.."

ZTS=./zig-out/bin/zts
REQ='{"schema_version":2,"operation":"meta","project_root":".","input":{}}'

first=$(echo "$REQ" | "$ZTS" agent --stdin-json)
second=$(echo "$REQ" | "$ZTS" agent --stdin-json)
if [ "$first" != "$second" ]; then
  echo "error: agent meta response is not deterministic" >&2
  diff <(echo "$first") <(echo "$second") >&2 || true
  exit 1
fi
echo "$first" | python3 -c "import json,sys; json.loads(sys.stdin.read())"

# stdout carries the response and nothing else: stderr is discarded here, and a
# second parse of the same bytes proves no log line was interleaved.
for op in features restrictions describe_rule; do
  req="{\"schema_version\":2,\"operation\":\"$op\",\"project_root\":\".\",\"input\":{}}"
  a=$(echo "$req" | "$ZTS" agent --stdin-json 2>/dev/null)
  b=$(echo "$req" | "$ZTS" agent --stdin-json 2>/dev/null)
  [ "$a" = "$b" ] || { echo "error: $op response is not deterministic" >&2; exit 1; }
  echo "$a" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert d['operation']=='$op'"
done

# A file-bound operation, so the module-graph digest is in the loop too.
FILE=packages/tools/tests/fixtures/contract/plain_ts.ts
req="{\"schema_version\":2,\"operation\":\"check\",\"project_root\":\".\",\"input\":{\"file\":\"$FILE\"}}"
a=$(echo "$req" | "$ZTS" agent --stdin-json 2>/dev/null)
b=$(echo "$req" | "$ZTS" agent --stdin-json 2>/dev/null)
[ "$a" = "$b" ] || { echo "error: check response is not deterministic" >&2; exit 1; }

echo "agent determinism OK"
```

Wire it into `scripts/verify.sh` directly after the
`check-normalize-idempotent.sh` step, using the same `step "..."` wrapper.

- [x] **Step 2: The v1 non-regression gate.** `features --json`, `modules --json`,
and `restrictions --json` are already pinned by `test-contract-golden`, and
`meta --json`, `describe-rule ZTS303 --json`, and both `canonicalize` goldens by
`test-expert-golden`. Confirm both steps are green and that no golden file moved
in this phase:

```bash
zig build test-contract-golden
zig build test-expert-golden
git diff --stat main -- packages/tools/tests/fixtures/
```

Expected: both green, and the third command prints nothing. A moved fixture means
a v1 surface changed and the phase's exit criterion is not met - fix the code, not
the fixture.

- [x] **Step 3: Full local gate.** In order, all green:

```bash
zig build test
bash scripts/test-examples.sh
bash scripts/verify.sh
./zig-out/bin/zts spec-check --json
```

- [x] **Step 4: Manual smoke.** Record the actual output in this file under a
"Results" heading, the way the Phase 0 plan's Task 8 does:

```bash
echo '{"schema_version":2,"operation":"meta","project_root":".","input":{}}' | ./zig-out/bin/zts agent --stdin-json | python3 -m json.tool | head -40
echo '{"schema_version":7,"operation":"meta","project_root":".","input":{}}' | ./zig-out/bin/zts agent --stdin-json
echo '{"schema_version":2,"operation":"verify","project_root":".","input":{}}' | ./zig-out/bin/zts agent --stdin-json | python3 -m json.tool
echo '{"schema_version":2,"operation":"modules","project_root":".","input":{"file":"examples/handler/handler.ts"}}' | ./zig-out/bin/zts agent --stdin-json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['module_graph_hash'], len(d['payload']['graph']))"
./zig-out/bin/zts restrictions --json | python3 -c "import json,sys; print(len(json.load(sys.stdin)))"
```

- [x] **Step 5: Write `docs/internals/agent-protocol-v2.md`.** Contents: the
envelope, the operation table with each operation's status, the closed error-code
set including `operation_not_implemented`, the frozen negotiation response, the
`expected` guard rule, the diagnostic shape with its two Phase 1 gaps
(no `span`, `repair_available` always false), and a pointer to
`docs/internals/zts-expert-contract.md` for the v1 surfaces. Generate the
operation table by running `meta` rather than typing it.

- [x] **Step 6: Amend D3 §6.** Add `operation_not_implemented` to the protocol
error-code list with the one-line rationale from Task 5.

- [x] **Step 7: Append to the master plan's decision log.** Date the entry
2026-07-31 and record, at minimum:

- the restriction matrix is its own registry with its own hash, not rows in
  `all_rules` (Task 2 decision 1), and v1 `features` / `restrictions` output is
  frozen at today's 20 rows through `v1_feature_name` (decision 2);
- `operation_not_implemented` added to D3's closed error set (Task 5);
- rule severity is derived from category rather than stored, because a severity
  column would shift the policy hash (Task 7), with whatever the measurement in
  that task's Step 3 actually showed;
- `check` publishes `byte_offset` and no `span`, and `repair_available` is
  uniformly false until the validator registry exists (Task 9);
- the contract body stays a v1 surface (Task 9);
- `canonicalize` and `normalize` grade every candidate `proposed_refactor`, which
  is what spec 4.8 requires with no validator registry (Task 10);
- `meta` omits `grammar`, `examples`, `ambient_names`, `validators`,
  `type_serialization`, and `decisions`, listing them in `deferred_sections`
  rather than stubbing them (Task 11);
- the debts this phase records without fixing: no extension-manifest
  authentication (Task 4), no repair-iteration or tool-call budget (Task 11), and
  any restriction row that ended up with an `unenforced_note` (Task 2).

Also record every deviation the implementation actually made, in the Phase 0
plan's style: what the task assumed, what the code found, and what changed.

- [x] **Step 8: Commit**

```bash
git add -A && git commit -m "docs(plans): record phase 1 completion, decisions, and recorded debts"
```

---

## Self-review notes

- **Spec coverage.** 4.8's envelope, closed operation set, frozen negotiation,
  protocol error object, `expected` rule, determinism, stdout purity, and the
  success rule are Tasks 5, 6, 9, 12. The diagnostic shape is Task 9, partially:
  `span` and the bound repair object are the two named gaps, both recorded. The
  `meta` payload's registry-generated half is Task 11; the six sections that have
  no registry are declared deferred rather than faked. Section 12's "MUST be
  generated from the versioned profile registry" is Tasks 2-3. The `modules`
  operation's five required returns are Task 8, with extension manifests the one
  gap. D3 §3's seven pre-images: `source_digest` (Task 1), `module_graph_hash`
  (Task 4), `idiom_table_hash` (Task 11), the new `restriction_matrix_hash`
  (Task 2); `policy_hash`, `semantics_hash`, and `contract_hash` are unchanged and
  need no work. D3 §6's per-operation payload table is Tasks 7-11 for the eight
  implemented operations.
- **Deliberately out of Phase 1**, per the master plan: `simulate_edit`,
  `apply_repair`, and `verify` (Phase 6, needing the validator registry); the
  canonical formatter; the unified repair vocabulary; the lexical tightenings; the
  `type_serialization` artifact (Phase 2, D1).
- **Type consistency check.** `agent_identity.sourceDigest` returns `[64]u8`
  everywhere, matching `rule_registry.policyHash()` and
  `module_manifest.registryHashFromBindings`. `GraphRecord.hash` and
  `contextFreeHash()` are both `[64]u8` and both feed the envelope's
  `module_graph_hash`. `OperationSpec.status` is the single gate on dispatch and
  on `meta.payload.operations`, so a row cannot be dispatchable and unpublished.
  `ImportKind` tag names are written to the wire with `@tagName`, so adding a
  member is a wire-visible change and the enum is the schema.
- **Ordering.** Tasks 1-4 have no dependency on 5-11 and can land in any order
  among themselves; 5 depends on 1 and 4; 6-11 depend on 5; 3 depends on 2; 12
  depends on everything. Tasks 2-3 must land in the same push as the
  `module-boundary.allow` row, since the gate fails both an unlisted reach and an
  unused row.

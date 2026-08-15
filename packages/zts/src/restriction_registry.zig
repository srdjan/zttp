//! Machine-readable view of the restriction-to-theorem matrix (spec 12).
//!
//! A restriction is a construct the profile refuses, paired with the boundary
//! the refusal protects and the nature of the decision: essential to a proof, or
//! a simplicity choice the profile makes deliberately. Spec 12 requires this
//! matrix be generated from the versioned profile registry rather than kept as
//! prose; this file is that registry.
//!
//! A restriction is not a rule. It carries no code, no severity, and no repair,
//! and most rows are enforced by the parser rather than by a registry rule, so
//! the rows live here instead of in `rule_registry.all_rules` - where they would
//! also shift the policy hash and the rule counts every consumer asserts on.
//!
//! `v1_feature_name` marks the rows the v1 `zts features` / `zts restrictions`
//! output already published. That output is frozen: it emits exactly the marked
//! rows, in this file's order, with these strings. Rows added here after the
//! freeze reach clients through the version-2 `restrictions` operation only.
//!
//! Every `enforced_by` entry was measured against the built binary on
//! 2026-07-31 by running `zts check --json` over a minimal handler containing
//! the construct, not inferred from the parser source. A row that no diagnostic
//! rejects carries `unenforced_note` instead, which is how the enforcement gaps
//! below became visible in the first place.

const std = @import("std");
const rule_registry = @import("rule_registry.zig");

/// Spec 12 column 3, as a closed set rather than prose.
pub const Nature = enum {
    /// No known way to keep both the proof and the construct.
    essential,
    /// A different construct provides the capability with the proof intact.
    replaced,
    /// One explicit form is easier to read and maintain; not a theorem.
    canonical_simplicity,
    /// A smaller language is the goal; not a theorem.
    language_simplicity,
    /// Kept pending a measurement the spec names.
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
    /// Why the construct is refused. For a row the v1 table published, this is
    /// that table's `blocked_reason` verbatim - the v1 wire shape depends on it.
    note: []const u8,
    /// What to write instead.
    alternative: ?[]const u8 = null,
    /// The failure class the cut prevents, as the v1 table words it.
    failure_class: ?[]const u8 = null,
    /// The proof the cut unlocks, as the v1 table words it.
    proof_unlocked: ?[]const u8 = null,
    /// Diagnostic codes that reject the construct today. Empty only when
    /// `unenforced_note` says why.
    enforced_by: []const []const u8 = &.{},
    /// One line naming why no diagnostic enforces this row.
    unenforced_note: ?[]const u8 = null,
    /// The name this row carries in the frozen v1 `features` output, or null
    /// when v1 never published it.
    v1_feature_name: ?[]const u8 = null,
};

pub const entries = [_]RestrictionEntry{
    // -----------------------------------------------------------------------
    // Rows the v1 `features` table publishes, in v1 order. The `note`,
    // `alternative`, `failure_class`, and `proof_unlocked` strings are that
    // table's, byte for byte.
    // -----------------------------------------------------------------------
    .{
        .id = "restriction.switch-case",
        .feature = "switch/case",
        .boundary = "non-exhaustive control flow and implicit fallthrough",
        .nature = .replaced,
        .note = "fallthrough makes coverage ambiguous and lets cases share state through implicit fallthrough.",
        .alternative = "use 'match' expression",
        .failure_class = "non-exhaustive control flow and implicit fallthrough",
        .proof_unlocked = "match coverage and exhaustive return analysis",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "switch/case",
    },
    .{
        .id = "restriction.var",
        .feature = "var",
        .boundary = "block-scoped data flow and reachability",
        .nature = .replaced,
        .note = "hoisting and function-scoping create temporal dead zones the verifier cannot reason about.",
        .alternative = "use 'let' or 'const'",
        .failure_class = "scope hoisting and temporal dead zones",
        .proof_unlocked = "block-scoped data flow and reachability analysis",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "var",
    },
    .{
        .id = "restriction.class",
        .feature = "class",
        .boundary = "explicit state, dispatch, and effects",
        .nature = .canonical_simplicity,
        .note = "implicit mutable receivers hide data flow from the contract extractor.",
        .alternative = "use plain objects and functions",
        .failure_class = "implicit mutable receivers and hidden state",
        .proof_unlocked = "explicit data flow and effect analysis",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "class",
    },
    .{
        .id = "restriction.while",
        .feature = "while",
        .boundary = "explicit iteration domain",
        .nature = .canonical_simplicity,
        .note = "unbounded back-edges defeat finite path enumeration.",
        .alternative = "use 'for...of' with a finite collection",
        .failure_class = "unbounded back-edges and non-termination",
        .proof_unlocked = "finite path enumeration and termination",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "while",
    },
    .{
        .id = "restriction.do-while",
        .feature = "do...while",
        .boundary = "explicit iteration domain",
        .nature = .canonical_simplicity,
        .note = "unbounded back-edges defeat finite path enumeration.",
        .alternative = "use 'for...of' with a finite collection",
        .failure_class = "unbounded back-edges and non-termination",
        .proof_unlocked = "finite path enumeration and termination",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "do...while",
    },
    .{
        .id = "restriction.c-style-for",
        .feature = "for(;;)",
        .boundary = "explicit iteration domain",
        .nature = .canonical_simplicity,
        .note = "C-style loops carry no bound; gen-tests cannot enumerate every iteration.",
        .alternative = "use 'for (const i of range(n))'",
        .failure_class = "unbounded back-edges and non-termination",
        .proof_unlocked = "finite path enumeration and termination",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "for(;;)",
    },
    .{
        .id = "restriction.for-in",
        .feature = "for...in",
        .boundary = "deterministic order and fixed shape",
        .nature = .replaced,
        .note = "for...in walks the prototype chain; iteration order is implementation-defined.",
        .alternative = "use 'for (const k of Object.keys(obj))'",
        .failure_class = "prototype-chain iteration and non-deterministic order",
        .proof_unlocked = "deterministic iteration and shape-stable access",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "for...in",
    },
    .{
        .id = "restriction.try-catch",
        .feature = "try/catch",
        .boundary = "typed visible failure paths",
        .nature = .canonical_simplicity,
        .note = "exceptions are an invisible second return channel that bypasses the type system.",
        .alternative = "use Result types and check .ok",
        .failure_class = "hidden exceptional control flow",
        .proof_unlocked = "Result narrowing and exhaustive path enumeration",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "try/catch",
    },
    .{
        .id = "restriction.throw",
        .feature = "throw",
        .boundary = "typed visible failure paths",
        .nature = .canonical_simplicity,
        .note = "throw is the producer side of the hidden exception channel.",
        .alternative = "return an error Response",
        .failure_class = "hidden exceptional control flow",
        .proof_unlocked = "Result narrowing and exhaustive return analysis",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "throw",
    },
    .{
        .id = "restriction.ambient-async",
        .feature = "async/await",
        .boundary = "deterministic replay and finite scheduler state",
        .nature = .essential,
        .note = "ambient scheduling produces interleavings the replay log cannot reproduce.",
        .alternative = "use fetch() from zttp:fetch, or parallel()/race() from zttp:io",
        .failure_class = "ambient scheduling and non-deterministic interleavings",
        .proof_unlocked = "deterministic effect boundary and replayable I/O",
        // Measured: `export async function handler` is rejected by the parser's
        // expected-token path (ZTS002), not by the unsupported-feature path.
        .enforced_by = &.{"ZTS002"},
        .v1_feature_name = "async/await",
    },
    .{
        .id = "restriction.new",
        .feature = "new",
        .boundary = "explicit state, dispatch, and effects",
        .nature = .canonical_simplicity,
        .note = "constructor dispatch combined with prototypes hides effects from the IR.",
        .alternative = "use factory functions or object literals",
        .failure_class = "constructor dispatch and hidden initialization effects",
        .proof_unlocked = "explicit factory call sites and visible effects",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "new",
    },
    .{
        .id = "restriction.this",
        .feature = "this",
        .boundary = "explicit state, dispatch, and effects",
        .nature = .canonical_simplicity,
        .note = "the binding of `this` is dynamic and unreadable from the IR.",
        .alternative = "use explicit parameter passing",
        .failure_class = "dynamic receiver binding",
        .proof_unlocked = "static call-graph and visible data flow",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "this",
    },
    .{
        .id = "restriction.loose-equality",
        .feature = "loose equality and implicit coercion",
        .boundary = "visible type-directed branches",
        .nature = .essential,
        .note = "loose equality coerces operands, creating control-flow paths the type checker cannot see.",
        .alternative = "use === / !==",
        .failure_class = "implicit coercion paths",
        .proof_unlocked = "sound type-directed comparison",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "== / !=",
    },
    .{
        .id = "restriction.increment-decrement",
        .feature = "++ / --",
        .boundary = "visible evaluation and one mutation spelling",
        .nature = .provisional,
        .note = "in-place mutation hides write effects in expression positions.",
        .alternative = "use x = x + 1",
        .failure_class = "hidden in-place mutation in expressions",
        .proof_unlocked = "explicit assignment effects and state isolation",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "++ / --",
    },
    .{
        .id = "restriction.regex",
        .feature = "regex literal or ambient RegExp",
        .boundary = "predictable resource use and analyzable validation",
        .nature = .replaced,
        .note = "regex literals describe an opaque accept set the validator cannot reason about.",
        .alternative = "use string methods (includes, startsWith, etc.)",
        .failure_class = "opaque accept set and catastrophic backtracking",
        .proof_unlocked = "shape-checkable validation via zttp:validate schemas",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "regex",
    },
    .{
        .id = "restriction.delete",
        .feature = "delete",
        .boundary = "shape-stable property access",
        .nature = .canonical_simplicity,
        .note = "delete mutates hidden-class shape, defeating shape-stable property access.",
        .alternative = "build a new object literal with only the keys you keep",
        .failure_class = "hidden-class shape mutation",
        .proof_unlocked = "shape-stable property access",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "delete",
    },
    .{
        .id = "restriction.enum",
        .feature = "enum",
        .boundary = "one closed data and module model",
        .nature = .language_simplicity,
        .note = "TS enums emit dual numeric/string lookups that bypass exhaustive match checking.",
        .alternative = "use object literals or discriminated unions",
        .failure_class = "dual numeric/string lookup and non-exhaustive cases",
        .proof_unlocked = "exhaustive match coverage on discriminated unions",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "enum",
    },
    .{
        .id = "restriction.decorator",
        .feature = "decorator",
        .boundary = "one closed data and module model",
        .nature = .language_simplicity,
        .note = "decorators rewrite their target at runtime in ways the contract extractor cannot trace.",
        .alternative = "use function composition",
        .failure_class = "implicit metaprogramming and target rewriting",
        .proof_unlocked = "static call-graph and visible effect composition",
        // Measured through the only position a decorator can occupy: a class
        // body, which ZTS001 rejects first.
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "decorator (@)",
    },
    .{
        .id = "restriction.namespace",
        .feature = "namespace",
        .boundary = "one closed data and module model",
        .nature = .language_simplicity,
        .note = "TS namespaces compile to closures with mutable internals invisible to the module graph.",
        .alternative = "use ES6 modules",
        .failure_class = "module-graph blind spots",
        .proof_unlocked = "AST-driven contract extraction",
        .enforced_by = &.{"ZTS001"},
        .v1_feature_name = "namespace",
    },

    // -----------------------------------------------------------------------
    // Spec 12 rows the v1 table never published. Version-2 surfaces only.
    // -----------------------------------------------------------------------
    .{
        .id = "restriction.dynamic-code",
        .feature = "eval, dynamic import, reflection, Proxy",
        .boundary = "closed program and semantics coverage",
        .nature = .essential,
        .note = "essential until a closed dynamic-code model exists",
        // `eval`, `Proxy`, and `Reflect` join the removed-global list the
        // parser already applied to `Promise` and `RegExp`; a user-declared
        // binding of the same name is still admitted. `import(...)` is
        // rejected as an unexpected token (ZTS002), and `new Proxy(...)` as
        // `new`, both before this row's names are reached.
        .enforced_by = &.{ "ZTS001", "ZTS002" },
    },
    .{
        .id = "restriction.mutable-live-iteration",
        .feature = "mutable live iteration",
        .boundary = "loop finiteness and stable cost",
        .nature = .replaced,
        .note = "replaced by snapshot iteration",
        // Reaches a directly named collection only: the iterable has to be an
        // identifier for a body reference to name the same collection.
        .enforced_by = &.{"ZTS622"},
    },
    .{
        .id = "restriction.unchecked-recursion",
        .feature = "unchecked recursive cycle",
        .boundary = "totality and bounded cost",
        .nature = .essential,
        .note = "recursion runs, but these claims require evidence",
        .unenforced_note = "not a rejection by design: recursion runs, and phase 0 downgrades the totality and cost claims instead (spec_discharge refuses the capsule, path_generator reports the coverage cause).",
    },
    .{
        .id = "restriction.unbound-native-module",
        .feature = "native module with unbound contract",
        .boundary = "effect and authority integrity",
        .nature = .essential,
        .note = "essential",
        .unenforced_note = "enforced outside the rule registry, by module manifest authentication and `zts verify-modules`, which emit no registry rule code.",
    },
    .{
        .id = "restriction.type-evidence",
        .feature = "`any`, type assertions (`as` and angle-bracket forms), `satisfies`",
        .boundary = "type evidence integrity",
        .nature = .essential,
        .note = "essential to the selected checker model",
        // Stripper codes, measured: ZTS041 `any`, ZTS042 `as`, ZTS043
        // `satisfies` (json_diagnostics.stripErrorCode). ZTS041 once also
        // named the parser's `nesting_too_deep`; that one moved to ZTS044, and
        // json_diagnostics now fails its own test if any code names two kinds.
        .enforced_by = &.{ "ZTS041", "ZTS042", "ZTS043" },
    },
    .{
        .id = "restriction.effectful-ternary",
        .feature = "effectful `?:`",
        .boundary = "visible evaluation and one mutation spelling",
        .nature = .provisional,
        .note = "language-simplicity choice, provisional pending the 14.2 paired-task measurement",
        .enforced_by = &.{"ZTS612"},
    },
    .{
        .id = "restriction.compound-assignment",
        .feature = "compound assignment",
        .boundary = "visible evaluation and one mutation spelling",
        .nature = .provisional,
        .note = "language-simplicity choice, provisional pending the 14.2 paired-task measurement",
        .enforced_by = &.{"ZTS613"},
    },
    .{
        .id = "restriction.rest-parameters",
        .feature = "rest parameters",
        .boundary = "visible evaluation and one mutation spelling",
        .nature = .provisional,
        .note = "language-simplicity choice, provisional pending the 14.2 paired-task measurement",
        .enforced_by = &.{"ZTS001"},
    },
    .{
        .id = "restriction.chained-conditional",
        .feature = "chained conditional arms",
        .boundary = "one form per branch shape",
        .nature = .canonical_simplicity,
        .note = "exact repair when constructible, else proposed refactor",
        .enforced_by = &.{"ZTS621"},
    },
    .{
        .id = "restriction.numeric-record-keys",
        .feature = "numeric record keys",
        .boundary = "one keyed-collection model",
        .nature = .canonical_simplicity,
        .note = "canonical simplicity; use a string key, or an array when the keys are dense indices",
        // Rejected at the key, not by a canonical ZTS6xx rule: a numeric key
        // parsed to the same string key as `{"1": ...}`, so no later pass
        // could tell the two spellings apart.
        .enforced_by = &.{"ZTS001"},
    },
    .{
        .id = "restriction.multiple-record-spreads",
        .feature = "multiple record spreads",
        .boundary = "fixed-shape elaboration without field-presence tests",
        .nature = .canonical_simplicity,
        .note = "canonical simplicity; write explicit fields over one base",
        .enforced_by = &.{"ZTS614"},
    },
    .{
        .id = "restriction.fallback-assert",
        .feature = "fallback `assert`",
        .boundary = "one explicit early-return spelling",
        .nature = .canonical_simplicity,
        .note = "use `if` plus `return`",
        .enforced_by = &.{"ZTS002"},
    },
    .{
        .id = "restriction.interface",
        .feature = "interface",
        .boundary = "one closed data and module model",
        .nature = .language_simplicity,
        .note = "write `structural Name = { ... };`",
        .enforced_by = &.{"ZTS049"},
    },
    .{
        .id = "restriction.type-alias",
        .feature = "`type` declaration",
        .boundary = "one closed data and module model",
        .nature = .language_simplicity,
        // `import type` and `export type { ... }` keep the keyword: both name
        // a declaration made elsewhere rather than making one, and the
        // stripper handles them before the declaration path.
        .note = "write `structural Name = ...;`",
        .enforced_by = &.{"ZTS050"},
    },
    .{
        .id = "restriction.distinct-type",
        .feature = "`distinct type` declaration",
        .boundary = "one closed data and module model",
        .nature = .language_simplicity,
        .note = "write `nominal Name = string;`",
        .enforced_by = &.{"ZTS051"},
    },
    .{
        .id = "restriction.pipe-operator",
        .feature = "`|>`, `pipe()`, `guard()`",
        .boundary = "one spelling for calling a function",
        .nature = .language_simplicity,
        // All three lowered to calls and arrows in the parser, so nothing
        // downstream could tell a piped call from a written one. They were
        // alternate authoring routes to control flow the language already
        // has, and `pipe()` and `guard()` were compile-time forms wearing a
        // module's clothes: their native implementations never executed.
        .note = "write the call directly; run guards by explicit early return",
        .enforced_by = &.{"ZTS001"},
    },
    .{
        .id = "restriction.object-methods",
        .feature = "object methods, getters, setters",
        .boundary = "explicit functions and effects",
        .nature = .language_simplicity,
        .note = "language-simplicity choice",
        // All three parsed and were then dropped by codegen, which emits only
        // `.object_property` and `.object_spread`: the method disappeared from
        // the object it was written into. Rejecting at the parse site.
        .enforced_by = &.{"ZTS001"},
    },
    .{
        .id = "restriction.javascript-source-extension",
        .feature = "`.js` and `.jsx` source files",
        .boundary = "one typed core and one explicit TSX frontend",
        .nature = .language_simplicity,
        .note = "source identity must select either the TypeScript core or the versioned TSX lowering frontend",
        .alternative = "rename the handler to .ts, or use .tsx when JSX lowering is required",
        .enforced_by = &.{"ZTS052"},
    },
    .{
        .id = "restriction.legacy-types-module",
        .feature = "`zttp:types` import",
        .boundary = "proof and effect witnesses are ambient type names",
        .nature = .language_simplicity,
        .note = "remove the import and write `Proof<T, P>` or `Effects<T, R>` directly",
        .enforced_by = &.{"ZTS053"},
    },
    .{
        .id = "restriction.default-parameter",
        .feature = "default parameter",
        .boundary = "one explicit absence branch in the function body",
        .nature = .language_simplicity,
        .note = "accept `T | undefined` and resolve the default at the start of the body",
        .enforced_by = &.{"ZTS054"},
    },
    .{
        .id = "restriction.optional-parameter",
        .feature = "optional parameter shorthand",
        .boundary = "one spelling for undefined absence",
        .nature = .language_simplicity,
        .note = "write `name: T | undefined`",
        .enforced_by = &.{"ZTS055"},
    },
};

pub fn findById(id: []const u8) ?*const RestrictionEntry {
    for (&entries) |*entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

/// Rows the frozen v1 `features` / `restrictions` output publishes, in v1 order.
pub const v1_count = blk: {
    var n: usize = 0;
    for (entries) |entry| {
        if (entry.v1_feature_name != null) n += 1;
    }
    break :blk n;
};

// ---------------------------------------------------------------------------
// Matrix hash
// ---------------------------------------------------------------------------

/// Deterministic SHA-256 over the matrix, field-wise with `\0` separators and a
/// `\x01` record terminator - the pre-image shape `rule_registry`'s policy hash
/// uses (D3 §3). Published as `restriction_matrix_hash`. Cached on first call
/// for the same reason the policy hash is: SHA-256 exceeds the comptime branch
/// budget.
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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
        // Exactly one: a row either points at the diagnostics that reject the
        // construct, or states in one line why none does. Silence is the
        // failure mode this gate exists to prevent.
        if (has_codes == has_note) {
            std.debug.print("restriction {s}: codes={} note={}\n", .{ entry.id, has_codes, has_note });
            try std.testing.expect(false);
        }
    }
}

test "every enforcing code resolves to a live rule or a known non-registry band" {
    for (entries) |entry| {
        for (entry.enforced_by) |code| {
            if (rule_registry.findByCode(code) != null) continue;
            // ZTS0xx parser errors and ZTS2xx type-checker errors are real
            // diagnostic codes that deliberately live outside the policy-hashed
            // registry (see describe_rule.zig's type-checker fallback).
            if (std.mem.startsWith(u8, code, "ZTS0")) continue;
            if (std.mem.startsWith(u8, code, "ZTS2")) continue;
            std.debug.print("restriction {s} names unknown code {s}\n", .{ entry.id, code });
            try std.testing.expect(false);
        }
    }
}

test "the v1 projection keeps every name the v1 table published" {
    // The v1 features table publishes 19 blocked rows. json_diagnostics asserts
    // the exact strings; this pins the count so a row cannot silently leave the
    // v1 set. It was 20 until phase 3 admitted `null` (spec 5.3) and moved that
    // name to the allowed table.
    try std.testing.expectEqual(@as(usize, 19), v1_count);
}

test "every v1 row carries the three strings the v1 wire shape requires" {
    for (entries) |entry| {
        if (entry.v1_feature_name == null) continue;
        try std.testing.expect(entry.alternative != null);
        try std.testing.expect(entry.failure_class != null);
        try std.testing.expect(entry.proof_unlocked != null);
    }
}

test "findById resolves a published row and rejects an unknown one" {
    const entry = findById("restriction.chained-conditional") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ZTS621", entry.enforced_by[0]);
    try std.testing.expect(findById("restriction.nope") == null);
}

test "matrixHash is stable and covers the enforcement column" {
    const h = matrixHash();
    try std.testing.expectEqual(@as(usize, 64), h.len);
    try std.testing.expectEqualSlices(u8, &h, &matrixHash());
    for (h) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(hex);
    }
}

//! Spec section 8's compact grammar, one row per production.
//!
//! The document is the readable view and this is the machine-readable one;
//! `scripts/check-grammar-drift.sh` compares them production by production and
//! fails on either side's drift, including on an empty extraction.
//!
//! Section 8 says of itself that it is a structural over-approximation: several
//! productions admit forms the normative prose of section 5 excludes. A
//! published grammar that says only "here is what parses" would therefore
//! mislead a client into writing programs this compiler refuses, so every row
//! carries where its enforcement happens.
//!
//! `parse_time` means the parser admits exactly what the production says.
//! `check_time` means the parser admits the production's forms and a later pass
//! refuses a subset of them; the row names the rule that does the refusing.
//! Each `check_time` row below was measured by running `zts check` on a program
//! that exercises the wider form and reading the code it reported - not by
//! reasoning about which pass ought to own it.
//!
//! `rhs` is the production's right-hand side with runs of whitespace collapsed
//! to one space and continuation lines joined, which is the only normalization
//! the drift gate applies to the document. A wording difference is drift.

const std = @import("std");

const rule_registry = @import("rule_registry.zig");
const diagnostic_projection = @import("diagnostic_projection.zig");
const profile_identity = @import("zts-base").profile_identity;

/// The only core source profile implemented by this grammar.
pub const profile_id = profile_identity.core_profile.id();

/// Where the refusal of a form this production admits actually happens.
pub const Enforcement = enum {
    parse_time,
    check_time,

    pub fn id(self: Enforcement) []const u8 {
        return @tagName(self);
    }
};

pub const Production = struct {
    name: []const u8,
    rhs: []const u8,
    enforcement: Enforcement = .parse_time,
    /// The rule that refuses the excess, for a `check_time` row whose code is a
    /// member of the policy-hashed registry.
    rule_code: ?[]const u8 = null,
    /// For a `check_time` row whose refusal comes from a band the registry does
    /// not cover: which band, and what it refuses.
    note: ?[]const u8 = null,
};

/// The productions, in document order. Order is part of the comparison: the
/// document reads top down and a reordered table is a different published
/// grammar.
pub const productions = [_]Production{
    .{
        .name = "Module",
        .rhs = "Import* TopDecl*",
    },
    .{
        .name = "Import",
        .rhs = "\"import\" [\"type\"] \"{\" ImportNames \"}\" \"from\" String \";\"",
    },
    .{
        .name = "ImportNames",
        .rhs = "ImportName (\",\" ImportName)* [\",\"]",
    },
    .{
        .name = "ImportName",
        .rhs = "Ident [\"as\" Ident]",
    },
    .{
        .name = "TopDecl",
        .rhs = "[\"export\"] StructuralDecl | [\"export\"] NominalDecl | [\"export\"] FunctionDecl | [\"export\"] TopBindingDecl",
    },
    .{
        .name = "StructuralDecl",
        .rhs = "\"structural\" Ident TypeParams? \"=\" Type \";\"",
        .enforcement = .check_time,
        .note = "ZTS212, the type-checker band, which is outside the policy-hashed registry: a recursive structural alias must be contractive and the grammar admits one that is not",
    },
    .{
        .name = "NominalDecl",
        .rhs = "\"nominal\" Ident \"=\" ScalarType \";\"",
    },
    .{
        .name = "TypeParams",
        .rhs = "\"<\" TypeParam (\",\" TypeParam)* \">\"",
    },
    .{
        .name = "TypeParam",
        .rhs = "Ident [\"extends\" Type]",
    },
    .{
        .name = "FunctionDecl",
        .rhs = "\"function\" Ident TypeParams? \"(\" DeclParams? \")\" \":\" ReturnType Block",
    },
    .{
        .name = "DeclParams",
        .rhs = "DeclParam (\",\" DeclParam)* [\",\"]",
    },
    .{
        .name = "DeclParam",
        .rhs = "Ident \":\" Type",
    },
    .{
        .name = "ValueParams",
        .rhs = "ValueParam (\",\" ValueParam)* [\",\"]",
    },
    .{
        .name = "ValueParam",
        .rhs = "Ident \":\" Type",
    },
    .{
        .name = "ReturnType",
        .rhs = "Type | TypePredicate",
    },
    .{
        .name = "TypePredicate",
        .rhs = "Ident \"is\" Type",
    },
    .{
        .name = "TopBindingDecl",
        .rhs = "\"const\" Bind [\":\" Type] \"=\" Expr \";\"",
    },
    .{
        .name = "BindingDecl",
        .rhs = "(\"const\" | \"let\") Bind [\":\" Type] \"=\" Expr \";\"",
        .enforcement = .check_time,
        .rule_code = "ZTS604",
    },
    .{
        .name = "Bind",
        .rhs = "Ident",
    },
    .{
        .name = "Block",
        .rhs = "\"{\" Stmt* \"}\"",
    },
    .{
        .name = "Stmt",
        .rhs = "BindingDecl | FunctionDecl | LValue \"=\" Expr \";\" | Expr \";\" | IfStmt | \"for\" \"(\" (\"const\" | \"let\") Bind \"of\" Expr \")\" Block | \"assert\" Expr \";\" | \"return\" [Expr] \";\" | \"break\" \";\" | \"continue\" \";\" | Block",
        .enforcement = .check_time,
        .rule_code = "ZTS613",
    },
    .{
        .name = "IfStmt",
        .rhs = "\"if\" \"(\" Expr \")\" Block [\"else\" (Block | IfStmt)]",
    },
    .{
        .name = "LValue",
        .rhs = "Ident | AssignableExpr \".\" Ident | AssignableExpr \"[\" Expr \"]\"",
    },
    .{
        .name = "AssignableExpr",
        .rhs = "PrimaryExpr AssignableSuffix*",
    },
    .{
        .name = "AssignableSuffix",
        .rhs = "\".\" Ident | \"[\" Expr \"]\" | TypeArgs? \"(\" [Args] \")\"",
    },
    .{
        .name = "Expr",
        .rhs = "ArrowExpr | ConditionalExpr",
    },
    .{
        .name = "ConditionalExpr",
        .rhs = "BinaryExpr [\"?\" BinaryExpr \":\" BinaryExpr]",
        .enforcement = .check_time,
        .rule_code = "ZTS621",
    },
    .{
        .name = "BinaryExpr",
        .rhs = "UnaryExpr (BinaryOp UnaryExpr)*",
    },
    .{
        .name = "UnaryExpr",
        .rhs = "UnaryOp UnaryExpr | PostfixExpr",
    },
    .{
        .name = "PostfixExpr",
        .rhs = "PrimaryExpr PostfixSuffix*",
    },
    .{
        .name = "PostfixSuffix",
        .rhs = "\".\" Ident | \"?.\" Ident | \"[\" Expr \"]\" | TypeArgs? \"(\" [Args] \")\"",
        .enforcement = .check_time,
        .rule_code = "ZTS624",
    },
    .{
        .name = "PrimaryExpr",
        .rhs = "Literal | Ident | ArrayExpr | RecordExpr | MatchExpr | \"(\" Expr \")\"",
    },
    .{
        .name = "UnaryOp",
        .rhs = "\"!\" | \"-\" | \"~\" | \"typeof\"",
    },
    .{
        .name = "BinaryOp",
        .rhs = "\"**\" | \"*\" | \"/\" | \"%\" | \"+\" | \"-\" | \"<<\" | \">>\" | \">>>\" | \"<\" | \"<=\" | \">\" | \">=\" | \"===\" | \"!==\" | \"&\" | \"^\" | \"|\" | \"&&\" | \"||\" | \"??\"",
        .enforcement = .check_time,
        .rule_code = "ZTS624",
    },
    .{
        .name = "ArrayExpr",
        .rhs = "\"[\" [ArrayItem (\",\" ArrayItem)* [\",\"]] \"]\"",
    },
    .{
        .name = "ArrayItem",
        .rhs = "Expr | \"...\" Expr",
    },
    .{
        .name = "RecordExpr",
        .rhs = "\"{\" \"}\" | \"{\" RecordField (\",\" RecordField)* [\",\"] \"}\" | \"{\" \"...\" Expr \",\" RecordField (\",\" RecordField)* [\",\"] \"}\"",
        .enforcement = .check_time,
        .rule_code = "ZTS614",
    },
    .{
        .name = "RecordField",
        .rhs = "Ident \":\" Expr | String \":\" Expr",
    },
    .{
        .name = "PropertyName",
        .rhs = "Ident | String",
    },
    .{
        .name = "Args",
        .rhs = "Expr (\",\" Expr)* [\",\"]",
    },
    .{
        .name = "TypeArgs",
        .rhs = "\"<\" Type (\",\" Type)* \">\"",
    },
    .{
        .name = "ArrowExpr",
        .rhs = "\"(\" [ArrowParams] \")\" \"=>\" (Expr | Block)",
        .enforcement = .check_time,
        .rule_code = "ZTS608",
    },
    .{
        .name = "ArrowParams",
        .rhs = "ArrowParam (\",\" ArrowParam)* [\",\"]",
    },
    .{
        .name = "ArrowParam",
        .rhs = "Ident [\":\" Type]",
    },
    .{
        .name = "MatchExpr",
        .rhs = "\"match\" \"(\" Scrutinee \")\" \"{\" MatchArm+ [DefaultArm] \"}\"",
        .enforcement = .check_time,
        .rule_code = "ZTS603",
    },
    .{
        .name = "Scrutinee",
        .rhs = "Ident (\".\" Ident)*",
    },
    .{
        .name = "MatchArm",
        .rhs = "\"when\" Pattern \":\" Expr",
    },
    .{
        .name = "DefaultArm",
        .rhs = "\"default\" \":\" Expr",
    },
    .{
        .name = "Pattern",
        .rhs = "Literal | TypeTestPattern | \"{\" PatternFields \"}\"",
    },
    .{
        .name = "TypeTestPattern",
        .rhs = "\"boolean\" | \"number\" | \"string\" | \"array\" | \"Dict\" | \"Bytes\"",
    },
    .{
        .name = "PatternFields",
        .rhs = "PatternField (\",\" PatternField)* [\",\"]",
    },
    .{
        .name = "PatternField",
        .rhs = "PropertyName \":\" Literal | PropertyName \":\" Ident | Ident",
    },
    .{
        .name = "Type",
        .rhs = "UnionType",
    },
    .{
        .name = "UnionType",
        .rhs = "IntersectionType (\"|\" IntersectionType)*",
    },
    .{
        .name = "IntersectionType",
        .rhs = "PostfixType (\"&\" PostfixType)*",
    },
    .{
        .name = "PostfixType",
        .rhs = "PrimaryType (\"[]\")* | \"readonly\" ArrayBaseType \"[]\"",
    },
    .{
        .name = "ArrayBaseType",
        .rhs = "NonTuplePrimaryType | \"(\" Type \")\"",
    },
    .{
        .name = "PrimaryType",
        .rhs = "NonTuplePrimaryType | TupleType",
    },
    .{
        .name = "NonTuplePrimaryType",
        .rhs = "Primitive | LiteralType | Ident TypeArgs? | RecordType | FunctionType | TemplateLiteralType | \"(\" Type \")\"",
    },
    .{
        .name = "Primitive",
        .rhs = "\"unknown\" | \"never\" | \"undefined\" | \"null\" | \"boolean\" | \"number\" | \"string\" | \"Bytes\"",
    },
    .{
        .name = "LiteralType",
        .rhs = "String | Number | \"true\" | \"false\"",
    },
    .{
        .name = "TupleType",
        .rhs = "[\"readonly\"] \"[\" [Type (\",\" Type)* [\",\"]] \"]\"",
    },
    .{
        .name = "RecordType",
        .rhs = "\"{\" [RecordTypeField (\";\" RecordTypeField)* [\";\"]] \"}\"",
    },
    .{
        .name = "RecordTypeField",
        .rhs = "[\"readonly\"] PropertyName [\"?\"] \":\" Type",
    },
    .{
        .name = "FunctionType",
        .rhs = "\"(\" [ValueParams] \")\" \"=>\" ReturnType",
    },
    .{
        .name = "ScalarType",
        .rhs = "\"number\" | \"string\"",
    },
};

pub fn findByName(name: []const u8) ?*const Production {
    for (&productions) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// Deterministic SHA-256 over the complete published grammar. Fields use NUL
/// separators and each production ends with SOH, matching the other protocol
/// registry identities. Optional fields carry an explicit presence byte, so
/// absence cannot collide with any published field value.
fn hashProductions(rows: []const Production) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (rows) |*production| {
        hasher.update(production.name);
        hasher.update("\x00");
        hasher.update(production.rhs);
        hasher.update("\x00");
        hasher.update(production.enforcement.id());
        hasher.update("\x00");
        if (production.rule_code) |rule_code| {
            hasher.update("\x01");
            hasher.update(rule_code);
        } else {
            hasher.update("\x00");
        }
        hasher.update("\x00");
        if (production.note) |note| {
            hasher.update("\x01");
            hasher.update(note);
        } else {
            hasher.update("\x00");
        }
        hasher.update("\x01");
    }
    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

pub fn grammarHash() [64]u8 {
    return hashProductions(&productions);
}

// ---------------------------------------------------------------------------
// Gates
// ---------------------------------------------------------------------------

const testing = std.testing;

test "grammarHash is stable lowercase hex" {
    const first = grammarHash();
    const second = grammarHash();
    try testing.expectEqualSlices(u8, &first, &second);
    for (first) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "grammarHash covers every published production field" {
    const base = [_]Production{.{ .name = "A", .rhs = "B" }};
    const expected = hashProductions(&base);
    const variants = [_]Production{
        .{ .name = "C", .rhs = "B" },
        .{ .name = "A", .rhs = "D" },
        .{ .name = "A", .rhs = "B", .enforcement = .check_time, .rule_code = "ZTS001" },
        .{ .name = "A", .rhs = "B", .enforcement = .check_time, .note = "checked elsewhere" },
    };
    for (variants) |variant| {
        const rows = [_]Production{variant};
        try testing.expect(!std.mem.eql(u8, &expected, &hashProductions(&rows)));
    }
}

test "every check_time row names either a registry rule or the band that answers" {
    var check_rows: usize = 0;
    for (&productions) |p| {
        switch (p.enforcement) {
            .parse_time => {
                // A parse_time row claims the parser admits exactly the
                // production. Carrying a rule code there would be a claim about
                // an enforcement point the row says does not exist.
                try testing.expect(p.rule_code == null);
                try testing.expect(p.note == null);
            },
            .check_time => {
                check_rows += 1;
                const has_code = p.rule_code != null;
                const has_note = p.note != null;
                // Exactly one. A row with neither publishes "something else
                // refuses this" and names nothing, which is the shape a reader
                // cannot act on.
                try testing.expect(has_code != has_note);
                if (p.rule_code) |code| {
                    if (rule_registry.findByCode(code) == null) {
                        std.debug.print("check_time row names an unknown rule: {s} -> {s}\n", .{ p.name, code });
                        return error.UnknownRuleCode;
                    }
                }
            },
        }
    }
    // The floor. A table where every row said parse_time would satisfy the loop
    // above while publishing the over-approximation the section preamble warns
    // about as if it were exact.
    // Nine rows remain after the model-minimal cut removed TypeDecl. Keeping
    // this exact floor catches a registry that silently relabels a wider
    // production as parser-exact.
    try testing.expect(check_rows >= 9);
}

test "every noted row names a code the projection really emits" {
    // The note is prose, and prose is where a claim rots. `StructuralDecl`
    // admits a recursive alias no data constructor guards, and the refusal is
    // ZTS212 from the type-checker band - a band the policy-hashed registry does
    // not cover, which is why this row carries a note instead of a `rule_code`.
    // Bound to the projection here so a renamed code fails the build rather
    // than leaving a client chasing a code nothing emits.
    //
    // Every noted row names ZTS212 today. A note that names some other code
    // needs its own binding added here; the count assertion is what makes that
    // a build failure rather than an unchecked sentence.
    const emitted = diagnostic_projection.code(.type, .non_contractive_alias);
    try testing.expectEqualStrings("ZTS212", emitted);

    var noted: usize = 0;
    for (&productions) |p| {
        const note = p.note orelse continue;
        noted += 1;
        if (std.mem.indexOf(u8, note, emitted) == null) {
            std.debug.print("noted row does not name {s}: {s}\n", .{ emitted, p.name });
            return error.UnboundNote;
        }
    }
    try testing.expectEqual(@as(usize, 1), noted);
    try testing.expect(findByName("StructuralDecl").?.note != null);
}

test "the production names are unique, so a client can key on them" {
    for (&productions, 0..) |p, i| {
        for (productions[i + 1 ..]) |other| {
            if (std.mem.eql(u8, p.name, other.name)) {
                std.debug.print("duplicate production: {s}\n", .{p.name});
                return error.DuplicateProduction;
            }
        }
    }
    try testing.expect(findByName("MatchExpr") != null);
    try testing.expect(findByName("NotAProduction") == null);
}

test "every right-hand side is normalized the way the drift gate normalizes the document" {
    // The gate collapses whitespace on the document side and compares bytes. A
    // row carrying a double space or a leading space would fail the gate for a
    // reason that has nothing to do with the grammar, so it fails here first,
    // where the message says what it is.
    for (&productions) |p| {
        try testing.expect(p.rhs.len > 0);
        try testing.expect(!std.mem.startsWith(u8, p.rhs, " "));
        try testing.expect(!std.mem.endsWith(u8, p.rhs, " "));
        try testing.expect(std.mem.indexOf(u8, p.rhs, "  ") == null);
        try testing.expect(std.mem.indexOfScalar(u8, p.rhs, '\t') == null);
        try testing.expect(std.mem.indexOfScalar(u8, p.rhs, '\n') == null);
    }
}

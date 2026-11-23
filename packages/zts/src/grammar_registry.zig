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
const diagnostic_catalog = @import("diagnostic_catalog.zig");
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
        .rhs = "[\"export\"] TypeAliasDecl | [\"export\"] UniqueSymbolDecl | [\"export\"] FunctionDecl | [\"export\"] TopBindingDecl | RegistrationCall",
    },
    .{
        .name = "TypeAliasDecl",
        .rhs = "\"type\" Ident TypeParams? \"=\" Type \";\"",
        .enforcement = .check_time,
        .note = "ZTS212, the type-checker band, which is outside the policy-hashed registry: a recursive type alias must be contractive and the grammar admits one that is not",
    },
    .{
        .name = "UniqueSymbolDecl",
        .rhs = "\"declare\" \"const\" Ident \":\" \"unique\" \"symbol\" \";\"",
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
        .name = "RegistrationCall",
        .rhs = "Ident \"(\" RegistrationArg (\",\" RegistrationArg)* [\",\"] \")\" \";\"",
        .enforcement = .check_time,
        .note = "ZTS074, the parser band, which is outside the policy-hashed registry: the callee must be an import of `sql` from zttp:sql or of `schemaCompile` from zttp:validate, and the grammar admits any identifier",
    },
    .{
        .name = "RegistrationArg",
        .rhs = "String | Number | \"true\" | \"false\" | \"null\"",
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
        .rhs = "BindingDecl | LValue \"=\" Expr \";\" | Expr \";\" | IfStmt | \"for\" \"(\" (\"const\" | \"let\") Bind \"of\" Expr \")\" Block | \"return\" [Expr] \";\" | \"break\" \";\" | \"continue\" \";\"",
        .enforcement = .check_time,
        .rule_code = "ZTS613",
    },
    .{
        .name = "IfStmt",
        .rhs = "\"if\" \"(\" Expr \")\" Block [\"else\" (Block | IfStmt)]",
    },
    .{
        .name = "LValue",
        .rhs = "Ident AssignableSuffix*",
    },
    .{
        .name = "AssignableSuffix",
        .rhs = "\".\" Ident | \"[\" Expr \"]\"",
    },
    .{
        .name = "Expr",
        .rhs = "ConditionalExpr",
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
        .rhs = "Literal | Ident | ArrayExpr | RecordExpr | \"(\" Expr \")\"",
    },
    .{
        .name = "UnaryOp",
        .rhs = "\"!\" | \"-\" | \"typeof\"",
    },
    .{
        .name = "BinaryOp",
        .rhs = "\"*\" | \"/\" | \"%\" | \"+\" | \"-\" | \"<\" | \"<=\" | \">\" | \">=\" | \"===\" | \"!==\" | \"&&\" | \"||\" | \"??\"",
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
        .name = "Args",
        .rhs = "Arg (\",\" Arg)* [\",\"]",
    },
    .{
        .name = "Arg",
        .rhs = "Expr | ArrowExpr",
    },
    .{
        .name = "TypeArgs",
        .rhs = "\"<\" Type (\",\" Type)* \">\"",
    },
    .{
        .name = "ArrowExpr",
        .rhs = "\"(\" [ArrowParams] \")\" \"=>\" (Expr | Block)",
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
        .rhs = "Primitive | LiteralType | Ident TypeArgs? | BrandQuery | RecordType | FunctionType | TemplateLiteralType | \"(\" Type \")\"",
    },
    .{
        .name = "BrandQuery",
        .rhs = "\"typeof\" Ident",
        .enforcement = .check_time,
        .note = "ZTS001, the parser band, admits this query only for a resolved unique-symbol brand used as the identity argument of imported Nominal",
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
    try testing.expectEqual(@as(usize, 9), check_rows);
}

test "every noted row names a code the projection really emits" {
    // The note is prose, and prose is where a claim rots. `TypeAliasDecl`
    // admits a recursive alias no data constructor guards, and the refusal is
    // ZTS212 from the type-checker band. `RegistrationCall` admits any identifier as
    // a callee, and the refusal is ZTS074 from the parser band. Neither band is
    // covered by the policy-hashed registry, which is why
    // these rows carry a note instead of a `rule_code`. Each note is bound to
    // the projection here so a renamed code fails the build rather than
    // leaving a client chasing a code nothing emits.
    //
    // Three rows carry a note today. A note that names some other code needs its
    // own binding added here; the count assertion is what makes that a build
    // failure rather than an unchecked sentence.
    const type_code = diagnostic_projection.code(.type, .non_contractive_alias);
    try testing.expectEqualStrings("ZTS212", type_code);
    const parser_code = diagnostic_catalog.parserCode(.top_level_statement);
    try testing.expectEqualStrings("ZTS074", parser_code);
    const query_code = diagnostic_catalog.parserCode(.unsupported_feature);
    try testing.expectEqualStrings("ZTS001", query_code);

    var noted: usize = 0;
    for (&productions) |p| {
        if (p.note != null) noted += 1;
    }
    try testing.expectEqual(@as(usize, 3), noted);
    try testing.expect(std.mem.indexOf(u8, findByName("RegistrationCall").?.note.?, parser_code) != null);
    const alias = findByName("TypeAliasDecl") orelse return error.TestExpectedEqual;
    const alias_note = alias.note orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, alias_note, type_code) != null);
    const query = findByName("BrandQuery") orelse return error.TestExpectedEqual;
    const query_note = query.note orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, query_note, query_code) != null);
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
    try testing.expect(findByName("MatchExpr") == null);
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

test "the grammar derives no form that the compiler refuses" {
    const has = struct {
        fn in(name: []const u8, needle: []const u8) bool {
            const p = findByName(name) orelse return false;
            return std.mem.indexOf(u8, p.rhs, needle) != null;
        }
    }.in;
    // A function declaration is module level only (ZTS071).
    try testing.expect(!has("Stmt", "FunctionDecl"));
    // A bare block is not a statement (ZTS001).
    try testing.expect(!has("Stmt", "| Block"));
    // An arrow is a direct call argument only (ZTS072).
    try testing.expect(!has("Expr", "ArrowExpr"));
    try testing.expect(has("Arg", "ArrowExpr"));
    // Exponentiation, bitwise, and shift operators are refused (ZTS001).
    try testing.expect(has("UnaryOp", "\"typeof\""));
    try testing.expect(!has("UnaryOp", "\"~\""));
    try testing.expect(has("BinaryOp", "\"&&\""));
    try testing.expect(!has("BinaryOp", "\"**\""));
    try testing.expect(!has("BinaryOp", "\"<<\""));
    try testing.expect(!has("BinaryOp", "\"&\""));
    try testing.expect(!has("BinaryOp", "\"^\""));
    try testing.expect(!has("BinaryOp", "\"|\""));
    // The registration call is the one top-level statement (ZTS074).
    try testing.expect(has("TopDecl", "RegistrationCall"));
    try testing.expect(has("TopDecl", "TypeAliasDecl"));
    try testing.expect(has("TopDecl", "UniqueSymbolDecl"));
    try testing.expect(has("NonTuplePrimaryType", "BrandQuery"));
    try testing.expect(!has("TopDecl", "StructuralDecl"));
    try testing.expect(!has("TopDecl", "NominalDecl"));
    try testing.expect(!has("Stmt", "\"assert\""));
    try testing.expect(!has("PrimaryExpr", "MatchExpr"));
}

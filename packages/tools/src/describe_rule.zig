//! `zts describe-rule` subcommand.
//!
//! Lists all rules, describes a specific rule by name or code, or outputs
//! the policy hash for CI assertions.

const std = @import("std");
const zts = @import("zts");
const policy_catalog = zts.PolicyCatalog;
const idiomCatalog = zts.IdiomCatalog;
const writeJsonString = zts.writeJsonString;

pub fn runWithArgs(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var json_mode = false;
    var hash_mode = false;
    var idiom_mode = false;
    var rule_name: ?[]const u8 = null;

    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--hash")) {
            hash_mode = true;
        } else if (std.mem.eql(u8, arg, "--idioms")) {
            idiom_mode = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // Unknown flag (e.g. a typo): reject loudly rather than ignoring it.
            return error.InvalidArgument;
        } else {
            rule_name = arg;
        }
    }

    if (hash_mode) {
        const hash = zts.policyHash();
        _ = std.c.write(std.c.STDOUT_FILENO, &hash, hash.len);
        _ = std.c.write(std.c.STDOUT_FILENO, "\n", 1);
        return;
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);

    // The idiom table (spec 4.2.1) is a separate surface from the diagnostic
    // rules: an idiom is never an error, so it has no code, category, or
    // severity. It gets its own flag rather than a key inside the rule list,
    // which ships as a bare JSON array that machine consumers already parse.
    if (idiom_mode) {
        if (json_mode) {
            try writeIdiomListJson(&aw.writer);
            try aw.writer.writeAll("\n");
        } else {
            try writeIdiomListText(&aw.writer);
        }
        buf = aw.toArrayList();
        if (buf.items.len > 0) {
            _ = std.c.write(std.c.STDOUT_FILENO, buf.items.ptr, buf.items.len);
        }
        return;
    }

    if (rule_name) |name| {
        const entry = policy_catalog.findByName(name) orelse
            policy_catalog.findByCode(name) orelse {
            // Type-checker codes (ZTS200-205) live in json_diagnostics, not the
            // rule_registry (the registry feeds the policy hash, so adding them
            // there would shift it). Describe them from a built-in fallback so
            // `describe-rule ZTS203` returns a real answer instead of "Unknown".
            if (findTypeCheckerRule(name)) |tc| {
                if (json_mode) {
                    try writeTypeCheckerJson(&aw.writer, tc);
                    try aw.writer.writeAll("\n");
                } else {
                    try writeTypeCheckerText(&aw.writer, tc);
                }
                buf = aw.toArrayList();
                if (buf.items.len > 0) {
                    _ = std.c.write(std.c.STDOUT_FILENO, buf.items.ptr, buf.items.len);
                }
                return;
            }
            if (json_mode) {
                // Machine consumers asked for JSON: keep the error in-band as a
                // JSON object on stdout instead of a plain-text stderr line.
                try writeUnknownRuleJson(&aw.writer, name);
                try aw.writer.writeAll("\n");
                buf = aw.toArrayList();
                _ = std.c.write(std.c.STDOUT_FILENO, buf.items.ptr, buf.items.len);
                std.process.exit(1);
            }
            try aw.writer.print("Unknown rule: {s}\n", .{name});
            buf = aw.toArrayList();
            _ = std.c.write(std.c.STDERR_FILENO, buf.items.ptr, buf.items.len);
            std.process.exit(1);
        };

        if (json_mode) {
            try writeRuleJson(&aw.writer, entry);
            try aw.writer.writeAll("\n");
        } else {
            try writeRuleText(&aw.writer, entry);
        }
    } else if (json_mode) {
        try aw.writer.writeAll("[");
        for (policy_catalog.rules(), 0..) |*entry, i| {
            if (i > 0) try aw.writer.writeAll(",");
            try writeRuleJson(&aw.writer, entry);
        }
        try aw.writer.writeAll("]\n");
    } else {
        try aw.writer.print("{s:<30} {s:<8} {s:<10} {s}\n", .{ "NAME", "CODE", "CATEGORY", "DESCRIPTION" });
        try aw.writer.writeAll("---\n");
        for (policy_catalog.rules()) |*entry| {
            try aw.writer.print("{s:<30} {s:<8} {s:<10} {s}\n", .{
                entry.name,
                entry.code,
                entry.category.label(),
                entry.description,
            });
        }
    }

    buf = aw.toArrayList();
    if (buf.items.len > 0) {
        _ = std.c.write(std.c.STDOUT_FILENO, buf.items.ptr, buf.items.len);
    }
}

pub fn writeRuleJson(writer: anytype, entry: *const policy_catalog.Rule) !void {
    try writer.writeAll("{\"name\":");
    try writeJsonString(writer, entry.name);
    try writer.writeAll(",\"code\":");
    try writeJsonString(writer, entry.code);
    try writer.writeAll(",\"category\":");
    try writeJsonString(writer, entry.category.label());
    try writer.writeAll(",\"description\":");
    try writeJsonString(writer, entry.description);
    if (entry.example) |ex| {
        try writer.writeAll(",\"example\":");
        try writeJsonString(writer, ex);
    }
    try writer.writeAll(",\"help\":");
    try writeJsonString(writer, entry.help);
    // Slice B: surface the typed repair primitive so `zttp expert` can pick
    // an apply primitive without parsing the prose help. Emitted only when a
    // repair is registered for the rule; null repairs stay absent so older
    // consumers see no schema change for unrepairable diagnostics.
    if (entry.repair) |r| {
        try writer.writeAll(",\"repair_intent\":");
        try writeJsonString(writer, r.asString());
    }
    try writer.writeAll("}");
}

pub fn writeIdiomJson(writer: anytype, entry: *const idiomCatalog.Idiom) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, entry.id);
    try writer.writeAll(",\"operation\":");
    try writeJsonString(writer, entry.operation);
    try writer.writeAll(",\"idiomatic\":");
    try writeJsonString(writer, entry.idiomatic);
    try writer.writeAll(",\"superseded\":");
    try writeJsonString(writer, entry.superseded);
    try writer.writeAll(",\"precondition\":");
    try writeJsonString(writer, entry.precondition);
    try writer.writeAll(",\"rewrite_rule\":");
    if (entry.rewrite_rule) |rule| {
        try writeJsonString(writer, rule);
    } else {
        // Emitted as an explicit null, not omitted: absence is the signal that
        // the row is advisory-only, so a consumer must be able to see it.
        try writer.writeAll("null");
    }
    try writer.writeAll("}");
}

pub fn writeIdiomListJson(writer: anytype) !void {
    try writer.writeAll("{\"idioms\":[");
    for (idiomCatalog.idioms(), 0..) |*entry, i| {
        if (i > 0) try writer.writeAll(",");
        try writeIdiomJson(writer, entry);
    }
    try writer.writeAll("]}");
}

fn writeIdiomListText(writer: anytype) !void {
    try writer.print("{s:<28} {s:<24} {s}\n", .{ "ID", "OPERATION", "IDIOMATIC" });
    try writer.writeAll("---\n");
    for (idiomCatalog.idioms()) |*entry| {
        try writer.print("{s:<28} {s:<24} {s}\n", .{ entry.id, entry.operation, entry.idiomatic });
    }
}

fn writeRuleText(writer: anytype, entry: *const policy_catalog.Rule) !void {
    try writer.print("Rule: {s}\n", .{entry.name});
    try writer.print("Code: {s}\n", .{entry.code});
    try writer.print("Category: {s}\n", .{entry.category.label()});
    try writer.print("Description: {s}\n", .{entry.description});
    if (entry.example) |ex| {
        try writer.print("Example: {s}\n", .{ex});
    }
    try writer.print("Help: {s}\n", .{entry.help});
    if (entry.repair) |r| {
        try writer.print("Repair: {s}\n", .{r.asString()});
    }
}

/// Built-in description for a type-checker diagnostic. These codes are produced
/// by json_diagnostics.typeCheckerCode and are deliberately absent from the
/// policy-hashed rule_registry, so they need their own lightweight table here.
const TypeCheckerRule = struct {
    name: []const u8,
    code: []const u8,
    description: []const u8,
    /// What to do about it. Optional because a description that already says
    /// the fix needs no second sentence - but a rule a model provably could not
    /// act on needs one. ZTS204 is the measured case: workflow-queued-call
    /// never applied an edit in four recorded runs, cycling on a mismatch whose
    /// diagnostic said only that it was wrong.
    help: ?[]const u8 = null,
};

const type_checker_rules = [_]TypeCheckerRule{
    .{ .name = "type_mismatch", .code = "ZTS200", .description = "An expression's type does not match the type required by its context." },
    .{ .name = "missing_field", .code = "ZTS201", .description = "An object literal is missing a field required by the expected type." },
    .{ .name = "arg_count_mismatch", .code = "ZTS202", .description = "A call passes the wrong number of arguments for the callee's signature." },
    .{ .name = "arg_type_mismatch", .code = "ZTS203", .description = "A call argument's type does not match the parameter type in the callee's signature." },
    .{
        .name = "return_type_mismatch",
        .code = "ZTS204",
        .description = "A returned value's type does not match the function's declared return type.",
        .help = "Match the enclosing function's declared return type. A value handed back by a " ++
            "virtual-module call is usually not the declared type itself - `call()` answers an " ++
            "object, so `return Response.json(result)` rather than `return call(...)`. When the " ++
            "mismatch is inside a callback, the call that takes that callback reports its type, " ++
            "so the line to change is the callback's own return.",
    },
    .{ .name = "non_exhaustive_match", .code = "ZTS205", .description = "A match expression does not cover every possible case of the matched value." },
    .{ .name = "unknown_virtual_module", .code = "ZTS206", .description = "An import names a zttp virtual module that the active module catalog does not publish." },
    .{ .name = "missing_virtual_module_export", .code = "ZTS207", .description = "An import names an export that the selected zttp virtual module does not publish." },
    .{ .name = "ambiguous_type_argument", .code = "ZTS208", .description = "A generic call leaves a type parameter that no argument position determines; name it at the call site." },
    .{ .name = "type_constraint_violation", .code = "ZTS209", .description = "A type argument is outside the `extends` bound its type parameter declares." },
    .{ .name = "type_argument_count_mismatch", .code = "ZTS210", .description = "A call gives a different number of explicit type arguments than the signature declares type parameters." },
    .{ .name = "non_contractive_alias", .code = "ZTS212", .description = "A recursive type alias has a cycle that no record, tuple, or array constructor guards, so it describes an infinite type rather than a finite one." },
    .{ .name = "unencodable_json_payload", .code = "ZTS213", .description = "A `Response.json` payload has a type JSON cannot carry - a function, or a `Bytes`. The encoder would throw at run time, and the subset has no `try/catch` to handle it." },
    .{ .name = "invalid_type_predicate", .code = "ZTS211", .description = "A `value is T` predicate is not verified by its body; only a single return of admitted narrowing tests over the named parameter installs a guard." },
};

fn findTypeCheckerRule(query: []const u8) ?TypeCheckerRule {
    for (type_checker_rules) |r| {
        if (std.mem.eql(u8, r.code, query) or std.mem.eql(u8, r.name, query)) {
            return r;
        }
    }
    return null;
}

fn writeTypeCheckerJson(writer: anytype, rule: TypeCheckerRule) !void {
    try writer.writeAll("{\"name\":");
    try writeJsonString(writer, rule.name);
    try writer.writeAll(",\"code\":");
    try writeJsonString(writer, rule.code);
    try writer.writeAll(",\"category\":");
    try writeJsonString(writer, "type");
    try writer.writeAll(",\"description\":");
    try writeJsonString(writer, rule.description);
    if (rule.help) |help| {
        try writer.writeAll(",\"help\":");
        try writeJsonString(writer, help);
    }
    try writer.writeAll("}");
}

fn writeTypeCheckerText(writer: anytype, rule: TypeCheckerRule) !void {
    try writer.print("Rule: {s}\n", .{rule.name});
    try writer.print("Code: {s}\n", .{rule.code});
    try writer.print("Category: {s}\n", .{"type"});
    try writer.print("Description: {s}\n", .{rule.description});
    if (rule.help) |help| try writer.print("Help: {s}\n", .{help});
}

/// Build the `--json` unknown-rule error object, matching the branch in
/// `runWithArgs` that runs when no rule matches and `json_mode` is set. Kept as
/// a tiny helper purely so the JSON shape is unit-testable without driving
/// `runWithArgs` (which `std.process.exit`s).
fn writeUnknownRuleJson(writer: anytype, query: []const u8) !void {
    try writer.writeAll("{\"error\":\"unknown_rule\",\"query\":");
    try writeJsonString(writer, query);
    try writer.writeAll("}");
}

fn printHelp() void {
    const help =
        \\zts describe-rule - describe diagnostic rules
        \\
        \\Usage:
        \\  zts describe-rule [rule-name|code] [--json] [--hash] [--idioms]
        \\
        \\Options:
        \\  --json    Output as JSON
        \\  --hash    Output policy hash (SHA-256 of all rule metadata)
        \\  --idioms  List the idiom table instead of the diagnostic rules
        \\
        \\With no arguments, lists all rules.
        \\
    ;
    _ = std.c.write(std.c.STDOUT_FILENO, help.ptr, help.len);
}

const testing = std.testing;

test "findTypeCheckerRule resolves ZTS203 by code and name" {
    const by_code = findTypeCheckerRule("ZTS203") orelse return error.TestExpectedRule;
    try testing.expectEqualStrings("arg_type_mismatch", by_code.name);
    try testing.expectEqualStrings("ZTS203", by_code.code);

    const by_name = findTypeCheckerRule("arg_type_mismatch") orelse return error.TestExpectedRule;
    try testing.expectEqualStrings("ZTS203", by_name.code);

    try testing.expect(findTypeCheckerRule("ZTS999") == null);
}

test "writeUnknownRuleJson emits a JSON error object for an unknown rule" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try writeUnknownRuleJson(&aw.writer, "BOGUS");
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"error\":\"unknown_rule\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"query\":\"BOGUS\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Unknown rule") == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("unknown_rule", parsed.value.object.get("error").?.string);
    try testing.expectEqualStrings("BOGUS", parsed.value.object.get("query").?.string);
}

test "writeIdiomListJson emits every registry row with a stable id" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try writeIdiomListJson(&aw.writer);
    const out = aw.writer.buffered();

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();

    const idioms = parsed.value.object.get("idioms").?.array;
    try testing.expectEqual(idiomCatalog.idioms().len, idioms.items.len);
    for (idioms.items) |item| {
        const obj = item.object;
        try testing.expect(std.mem.startsWith(u8, obj.get("id").?.string, "idiom."));
        try testing.expect(obj.get("operation").?.string.len > 0);
        try testing.expect(obj.get("idiomatic").?.string.len > 0);
        try testing.expect(obj.get("superseded").?.string.len > 0);
        try testing.expect(obj.get("precondition").?.string.len > 0);
        // The key is always present: an absent rewrite is the signal that the
        // row is advisory-only, so a consumer has to be able to see the null.
        _ = obj.get("rewrite_rule") orelse return error.MissingRewriteRuleKey;
    }
}

test "writeTypeCheckerJson emits the rule-json shape with a real description" {
    const rule = findTypeCheckerRule("ZTS203") orelse return error.TestExpectedRule;
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try writeTypeCheckerJson(&aw.writer, rule);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"code\":\"ZTS203\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"arg_type_mismatch\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"description\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Unknown rule") == null);
}

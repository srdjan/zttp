//! Round trip of the consumer declaration's canonical form, `ZTDCL1` (M4 T5b):
//! the zts loader and encoder on one side, the acceptance kernel's zero-copy
//! decoder on the other. This file sees both, which neither package can.
//!
//! The producer and the kernel each hold the magic, the schema, the digest
//! domain, and the profile wire order. The comptime block and the first test
//! fail when they disagree.

const std = @import("std");
const zts = @import("zts");
const pcc = @import("zttp_proof_checker");

const declaration = zts.declaration;
const capability_profiles = zts.capability_profiles;
const kernel = pcc.declaration;

comptime {
    if (!std.mem.eql(u8, declaration.canonical_magic, kernel.magic)) @compileError("ZTDCL1 encoder and kernel decoder disagree on the magic");
    if (declaration.canonical_schema != kernel.schema_version) @compileError("ZTDCL1 encoder and kernel decoder disagree on the schema");
    if (!std.mem.eql(u8, declaration.digest_domain, kernel.digest_domain)) @compileError("ZTDCL1 encoder and kernel decoder disagree on the digest domain");
}

const testing = std.testing;

test "the kernel's profile codes name the zts profile table in the same order" {
    const tags = std.meta.tags(kernel.Profile);
    try testing.expectEqual(capability_profiles.profiles.len, tags.len);
    for (tags) |tag| {
        const row = capability_profiles.profiles[@intFromEnum(tag)];
        try testing.expectEqualStrings(@tagName(tag), row.name);
    }
}

fn parseOk(bytes: []const u8) !declaration.Declaration {
    const result = try declaration.parse(testing.allocator, bytes);
    return switch (result) {
        .ok => |d| d,
        .refused => |r| {
            std.debug.print("refused: {s}\n", .{@tagName(r.reason)});
            return error.TestUnexpectedResult;
        },
    };
}

const authored =
    \\{ "version": 2,
    \\  "classifications": [
    \\    { "source": "service:billing", "path": "card.token",
    \\      "label": "credential", "required": false, "reason": "Payment token." },
    \\    { "source": "fetch:api.example.com", "path": "customer.tax_id",
    \\      "label": "secret", "required": true, "reason": "Tax identifier." },
    \\    { "source": "fetch:api.example.com", "path": "customer.address",
    \\      "label": "secret", "required": false, "reason": "Postal address." } ],
    \\  "ceiling": { "profile": "adapter", "exclude": ["zttp:sql", "zttp:durable", "zttp:cache"] } }
;

/// The same meaning: every list and every object key in another order.
const reordered =
    \\{ "ceiling": { "exclude": ["zttp:cache", "zttp:sql", "zttp:durable"], "profile": "adapter" },
    \\  "classifications": [
    \\    { "reason": "Tax identifier.", "required": true, "label": "secret",
    \\      "path": "customer.tax_id", "source": "fetch:api.example.com" },
    \\    { "source": "fetch:api.example.com", "path": "customer.address",
    \\      "label": "secret", "required": false, "reason": "Postal address." },
    \\    { "source": "service:billing", "path": "card.token",
    \\      "label": "credential", "required": false, "reason": "Payment token." } ],
    \\  "version": 2 }
;

test "a version 2 declaration survives parse, encodeCanonical, and kernel decode field for field" {
    var decl = try parseOk(authored);
    defer decl.deinit();
    const bytes = try declaration.encodeCanonical(testing.allocator, &decl);
    defer testing.allocator.free(bytes);

    const decoded = try kernel.decode(bytes);
    try testing.expectEqual(decl.classifications.len, decoded.classification_count);
    var it = decoded.classifications();
    for (decl.classifications) |want| {
        const got = (try it.next()) orelse return error.TestMissingClassification;
        try testing.expectEqualStrings(@tagName(want.source_kind), @tagName(got.source_kind));
        try testing.expectEqualStrings(want.source_name, got.source_name);
        try testing.expectEqualStrings(want.path_text, got.path);
        try testing.expectEqualStrings(@tagName(want.label), @tagName(got.label));
        try testing.expectEqual(want.required, got.required);
        try testing.expectEqualStrings(want.reason, got.reason);
    }
    try testing.expectEqual(@as(?kernel.Classification, null), try it.next());

    const want_ceiling = decl.ceiling orelse return error.TestMissingCeiling;
    const got_ceiling = decoded.ceiling orelse return error.TestMissingCeiling;
    try testing.expectEqualStrings(want_ceiling.profile.name, @tagName(got_ceiling.profile));
    try testing.expectEqual(want_ceiling.exclude.len, got_ceiling.exclude_count);
    var excludes = got_ceiling.excludes();
    for (want_ceiling.exclude) |want| {
        const got = (try excludes.next()) orelse return error.TestMissingExclude;
        try testing.expectEqualStrings(want, got);
    }
    try testing.expectEqual(@as(?[]const u8, null), try excludes.next());

    try testing.expectEqualSlices(u8, &declaration.digest(bytes), &kernel.digest(bytes));
}

test "two differently ordered documents with the same meaning encode to identical bytes and digest" {
    var a = try parseOk(authored);
    defer a.deinit();
    var b = try parseOk(reordered);
    defer b.deinit();
    const ea = try declaration.encodeCanonical(testing.allocator, &a);
    defer testing.allocator.free(ea);
    const eb = try declaration.encodeCanonical(testing.allocator, &b);
    defer testing.allocator.free(eb);
    try testing.expectEqualSlices(u8, ea, eb);
    try testing.expectEqualSlices(u8, &kernel.digest(ea), &kernel.digest(eb));
    _ = try kernel.decode(eb);
}

test "a version 1 declaration and a ceiling-only declaration both decode in the kernel" {
    var v1 = try parseOk(
        \\{"version":1,"classifications":[{"source":"fetch:a.example","path":"a","label":"secret","required":true,"reason":"r"}]}
    );
    defer v1.deinit();
    const v1_bytes = try declaration.encodeCanonical(testing.allocator, &v1);
    defer testing.allocator.free(v1_bytes);
    const v1_decoded = try kernel.decode(v1_bytes);
    try testing.expectEqual(@as(u16, 1), v1_decoded.classification_count);
    try testing.expectEqual(@as(?kernel.Ceiling, null), v1_decoded.ceiling);

    var ceiling_only = try parseOk(
        \\{"version":2,"ceiling":{"profile":"boundary","exclude":[]}}
    );
    defer ceiling_only.deinit();
    const c_bytes = try declaration.encodeCanonical(testing.allocator, &ceiling_only);
    defer testing.allocator.free(c_bytes);
    const c_decoded = try kernel.decode(c_bytes);
    try testing.expectEqual(@as(u16, 0), c_decoded.classification_count);
    const ceiling = c_decoded.ceiling orelse return error.TestMissingCeiling;
    try testing.expectEqual(kernel.Profile.boundary, ceiling.profile);
    try testing.expectEqual(@as(u16, 0), ceiling.exclude_count);
}

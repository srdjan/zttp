//! Renders a virtual module's spec JSON from its typed Zig binding.
//!
//! The bindings are the source of truth; `packages/modules/module-specs/*.json`
//! is generated governance data. This mirrors `semantics_render.zig`, which
//! plays the same role for the semantics registry, and is paired with a
//! `--check` drift gate in the CLI.
//!
//! Pure string building, no filesystem access: the CLI owns I/O so the
//! analyzer stays usable from the wasm build.
//!
//! ## The output contract
//!
//! Formatting is a requirement, not taste, because `--check` compares bytes.
//! Two-space indent, `": "` after each key, one array element per line, empty
//! arrays inline as `[]`, and a trailing newline.
//!
//! The JSON is a deliberately LOSSY projection of the binding. `arg_count`,
//! `required_arg_count`, `traceable`, `replay_pure`, `contract_flags`,
//! `return_labels`, and `ContractExtraction.flag_only` all exist in Zig and
//! appear in no spec file. Widening the projection is a separate decision with
//! its own diff; do not add a field here just because the binding has one.
//!
//! Note the casing split: JSON keys are camelCase (`argPosition`,
//! `argumentShape`, `inverseOf`) while enum VALUES stay snake_case
//! (`empty_string_literal`, `result_err`, `optional_string`).

const std = @import("std");
const module_binding = @import("zts-engine").module_binding;

const ModuleBinding = module_binding.ModuleBinding;
const FunctionBinding = module_binding.FunctionBinding;

const Buf = std.ArrayList(u8);

fn appendJsonString(buf: *Buf, a: std.mem.Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\r' => try buf.appendSlice(a, "\\r"),
        '\t' => try buf.appendSlice(a, "\\t"),
        else => try buf.append(a, c),
    };
    try buf.append(a, '"');
}

fn appendInt(buf: *Buf, a: std.mem.Allocator, v: u8) !void {
    var tmp: [8]u8 = undefined;
    try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{v}));
}

fn indent(buf: *Buf, a: std.mem.Allocator, spaces: usize) !void {
    try buf.appendNTimes(a, ' ', spaces);
}

/// Write `"key": ` at `spaces` indentation.
fn key(buf: *Buf, a: std.mem.Allocator, spaces: usize, name: []const u8) !void {
    try indent(buf, a, spaces);
    try appendJsonString(buf, a, name);
    try buf.appendSlice(a, ": ");
}

/// Write a string array. Empty renders inline as `[]`, so the caller does not
/// need to branch. Non-empty puts one element per line at `spaces + 2`.
fn stringArray(buf: *Buf, a: std.mem.Allocator, spaces: usize, items: []const []const u8) !void {
    if (items.len == 0) {
        try buf.appendSlice(a, "[]");
        return;
    }
    try buf.appendSlice(a, "[\n");
    for (items, 0..) |item, i| {
        try indent(buf, a, spaces + 2);
        try appendJsonString(buf, a, item);
        if (i + 1 < items.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try indent(buf, a, spaces);
    try buf.append(a, ']');
}

fn renderExtractions(
    buf: *Buf,
    a: std.mem.Allocator,
    spaces: usize,
    extractions: []const module_binding.ContractExtraction,
) !void {
    try buf.appendSlice(a, "[\n");
    for (extractions, 0..) |x, i| {
        try indent(buf, a, spaces + 2);
        try buf.appendSlice(a, "{\n");

        // Canonical key order: category, then argPosition when it is not the
        // default, then transform when set. The committed files disagreed on
        // this - net/fetch.json led with argPosition - so one order is chosen
        // here and every file follows it.
        try key(buf, a, spaces + 4, "category");
        try appendJsonString(buf, a, @tagName(x.category));

        if (x.arg_position != 0) {
            try buf.appendSlice(a, ",\n");
            try key(buf, a, spaces + 4, "argPosition");
            try appendInt(buf, a, x.arg_position);
        }
        if (x.transform) |t| {
            try buf.appendSlice(a, ",\n");
            try key(buf, a, spaces + 4, "transform");
            try appendJsonString(buf, a, @tagName(t));
        }
        try buf.append(a, '\n');

        try indent(buf, a, spaces + 2);
        try buf.append(a, '}');
        if (i + 1 < extractions.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try indent(buf, a, spaces);
    try buf.append(a, ']');
}

fn renderLaws(
    buf: *Buf,
    a: std.mem.Allocator,
    spaces: usize,
    laws: []const module_binding.Law,
) !void {
    try buf.appendSlice(a, "[\n");
    for (laws, 0..) |law, i| {
        // Void variants render as bare strings, payload variants as objects.
        switch (law) {
            .pure, .idempotent_call => {
                try indent(buf, a, spaces + 2);
                try appendJsonString(buf, a, @tagName(law));
            },
            .inverse_of => |name| {
                try indent(buf, a, spaces + 2);
                try buf.appendSlice(a, "{\n");
                try key(buf, a, spaces + 4, "inverseOf");
                try appendJsonString(buf, a, name);
                try buf.append(a, '\n');
                try indent(buf, a, spaces + 2);
                try buf.append(a, '}');
            },
            .absorbing => |pat| {
                try indent(buf, a, spaces + 2);
                try buf.appendSlice(a, "{\n");
                try key(buf, a, spaces + 4, "absorbing");
                try buf.appendSlice(a, "{\n");
                try key(buf, a, spaces + 6, "argPosition");
                try appendInt(buf, a, pat.arg_position);
                try buf.appendSlice(a, ",\n");
                try key(buf, a, spaces + 6, "argumentShape");
                try appendJsonString(buf, a, @tagName(pat.argument_shape));
                try buf.appendSlice(a, ",\n");
                try key(buf, a, spaces + 6, "residue");
                try appendJsonString(buf, a, @tagName(pat.residue));
                try buf.append(a, '\n');
                try indent(buf, a, spaces + 4);
                try buf.appendSlice(a, "}\n");
                try indent(buf, a, spaces + 2);
                try buf.append(a, '}');
            },
        }
        if (i + 1 < laws.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try indent(buf, a, spaces);
    try buf.append(a, ']');
}

fn renderExport(buf: *Buf, a: std.mem.Allocator, exp: FunctionBinding) !void {
    try indent(buf, a, 4);
    try buf.appendSlice(a, "{\n");

    try key(buf, a, 6, "name");
    try appendJsonString(buf, a, exp.name);
    try buf.appendSlice(a, ",\n");

    // effect and returns are always written, including at their Zig defaults:
    // all 90 committed exports carry both.
    try key(buf, a, 6, "effect");
    try appendJsonString(buf, a, @tagName(exp.effect));
    try buf.appendSlice(a, ",\n");

    try key(buf, a, 6, "returns");
    try appendJsonString(buf, a, @tagName(exp.returns));

    if (exp.param_types.len > 0) {
        try buf.appendSlice(a, ",\n");
        try key(buf, a, 6, "params");
        var names: [64][]const u8 = undefined;
        // param_types is small by construction; no binding declares more than
        // a handful of parameters.
        std.debug.assert(exp.param_types.len <= names.len);
        for (exp.param_types, 0..) |p, i| names[i] = @tagName(p);
        try stringArray(buf, a, 6, names[0..exp.param_types.len]);
    }

    // Rendered beside `params` rather than merged into it: the kinds are what
    // the checker enforces and the names are what a caller reads, and a reader
    // of the spec must be able to tell which is which. Omitted when the export
    // has not been filled in yet, so the published spec never claims a name it
    // does not have.
    if (exp.param_names.len > 0) {
        try buf.appendSlice(a, ",\n");
        try key(buf, a, 6, "paramNames");
        var names: [64][]const u8 = undefined;
        std.debug.assert(exp.param_names.len <= names.len);
        for (exp.param_names, 0..) |p, i| names[i] = p;
        try stringArray(buf, a, 6, names[0..exp.param_names.len]);
    }

    // Rendered only when the export declares its own set. Absent means it
    // inherits the module's `requiredCapabilities` above, which is what an
    // untightened export does; present - including as an empty array - is the
    // export's own answer, and an empty array is the meaningful claim that this
    // export reaches nothing. Omitting it when present would leave the
    // published spec saying `parseBearer` needs crypto and clock while the
    // compiler knows it needs neither.
    if (exp.required_capabilities) |caps| {
        try buf.appendSlice(a, ",\n");
        try key(buf, a, 6, "requiredCapabilities");
        var names: [32][]const u8 = undefined;
        std.debug.assert(caps.len <= names.len);
        for (caps, 0..) |c, i| names[i] = @tagName(c);
        try stringArray(buf, a, 6, names[0..caps.len]);
    }

    // Omitted when `.none`, which is the Zig default and the "always succeeds"
    // case. 23 of 90 committed exports carry it.
    if (exp.failure_severity != .none) {
        try buf.appendSlice(a, ",\n");
        try key(buf, a, 6, "failureSeverity");
        try appendJsonString(buf, a, @tagName(exp.failure_severity));
    }

    if (exp.contract_extractions.len > 0) {
        try buf.appendSlice(a, ",\n");
        try key(buf, a, 6, "contractExtractions");
        try renderExtractions(buf, a, 6, exp.contract_extractions);
    }

    if (exp.laws.len > 0) {
        try buf.appendSlice(a, ",\n");
        try key(buf, a, 6, "laws");
        try renderLaws(buf, a, 6, exp.laws);
    }

    try buf.append(a, '\n');
    try indent(buf, a, 4);
    try buf.append(a, '}');
}

/// Render one module's spec JSON. Caller owns the result.
///
/// `source_path` is the module's implementation path, which lives in
/// `builtin_modules.builtin_governance_entries` rather than in the binding.
pub fn renderModuleSpec(
    allocator: std.mem.Allocator,
    binding: ModuleBinding,
    source_path: []const u8,
) ![]u8 {
    var buf: Buf = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n");

    try key(&buf, allocator, 2, "schemaVersion");
    try buf.appendSlice(allocator, "1,\n");

    try key(&buf, allocator, 2, "specifier");
    try appendJsonString(&buf, allocator, binding.specifier);
    try buf.appendSlice(allocator, ",\n");

    try key(&buf, allocator, 2, "source");
    try appendJsonString(&buf, allocator, source_path);
    try buf.appendSlice(allocator, ",\n");

    // Omitted when undeclared, so a module that has not been filled in yet
    // renders exactly as it does today rather than gaining an empty string.
    if (binding.summary.len > 0) {
        try key(&buf, allocator, 2, "summary");
        try appendJsonString(&buf, allocator, binding.summary);
        try buf.appendSlice(allocator, ",\n");
    }

    try key(&buf, allocator, 2, "requiredCapabilities");
    var caps: [32][]const u8 = undefined;
    std.debug.assert(binding.required_capabilities.len <= caps.len);
    for (binding.required_capabilities, 0..) |c, i| caps[i] = @tagName(c);
    try stringArray(&buf, allocator, 2, caps[0..binding.required_capabilities.len]);
    try buf.appendSlice(allocator, ",\n");

    try key(&buf, allocator, 2, "exports");
    try buf.appendSlice(allocator, "[\n");
    for (binding.exports, 0..) |exp, i| {
        try renderExport(&buf, allocator, exp);
        if (i + 1 < binding.exports.len) try buf.append(allocator, ',');
        try buf.append(allocator, '\n');
    }
    try indent(&buf, allocator, 2);
    try buf.appendSlice(allocator, "]\n");

    try buf.appendSlice(allocator, "}\n");

    return buf.toOwnedSlice(allocator);
}

/// Render the Module Catalog table for `docs/virtual-modules/README.md`.
/// Caller owns the result.
///
/// Rows are alphabetical by specifier, which is the order that file already
/// uses. That deliberately differs from the JSON specs, which follow `builtins`
/// registration order: each artifact keeps the order it had. Within a row,
/// export and capability order is binding order.
///
/// Takes the bindings as a slice rather than reading the registry, so this file
/// stays free of a dependency on `builtin_modules.zig` and matches
/// `renderModuleSpec`'s shape.
pub fn renderModuleCatalogTable(
    allocator: std.mem.Allocator,
    bindings: []const ModuleBinding,
) ![]u8 {
    var order_buf: [64]usize = undefined;
    std.debug.assert(bindings.len <= order_buf.len);
    const order = order_buf[0..bindings.len];
    for (order, 0..) |*slot, i| slot.* = i;

    const Sort = struct {
        list: []const ModuleBinding,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return std.mem.lessThan(u8, ctx.list[a].specifier, ctx.list[b].specifier);
        }
    };
    std.mem.sort(usize, order, Sort{ .list = bindings }, Sort.lessThan);

    var buf: Buf = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "| Module | Exports | Capabilities |\n");
    try buf.appendSlice(allocator, "|---|---|---|\n");

    for (order) |idx| {
        const binding = bindings[idx];
        try buf.appendSlice(allocator, "| `");
        try buf.appendSlice(allocator, binding.specifier);
        try buf.appendSlice(allocator, "` | ");
        for (binding.exports, 0..) |exp, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try buf.append(allocator, '`');
            try buf.appendSlice(allocator, exp.name);
            try buf.append(allocator, '`');
        }
        try buf.appendSlice(allocator, " | ");
        // `none` rather than an empty cell, matching the existing file.
        if (binding.required_capabilities.len == 0) {
            try buf.appendSlice(allocator, "none");
        } else {
            for (binding.required_capabilities, 0..) |cap, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.append(allocator, '`');
                try buf.appendSlice(allocator, @tagName(cap));
                try buf.append(allocator, '`');
            }
        }
        try buf.appendSlice(allocator, " |\n");
    }

    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
//
// These read the committed spec files and compare bytes per module, so a
// failure names WHICH module diverges. `data/cache.json` and `data/sql.json`
// were the only two files already in sync with their bindings when the
// generator landed (see the B3 plan, section 6), which makes them the
// byte-identity evidence: they cover formatting, key order, non-empty
// capabilities, `contractExtractions`, and `failureSeverity` against a file no
// generator wrote. The rest are pinned against the generator's own output once
// reviewed, which is what the `--check` gate then enforces.
// ---------------------------------------------------------------------------

const testing = std.testing;
const builtin_modules = @import("zts-engine").builtin_modules;
const file_io = @import("zts-engine").file_io;

fn renderBySpecifier(a: std.mem.Allocator, specifier: []const u8) ![]u8 {
    for (builtin_modules.builtins, builtin_modules.builtin_governance_entries) |binding, gov| {
        if (std.mem.eql(u8, gov.specifier, specifier)) {
            return renderModuleSpec(a, binding, gov.module_path);
        }
    }
    return error.NoSuchModule;
}

fn expectMatchesCommitted(a: std.mem.Allocator, specifier: []const u8) !void {
    var spec_path: []const u8 = "";
    for (builtin_modules.builtin_governance_entries) |gov| {
        if (std.mem.eql(u8, gov.specifier, specifier)) spec_path = gov.spec_path;
    }
    try testing.expect(spec_path.len > 0);

    const committed = try file_io.readFile(a, spec_path, 1 << 20);
    defer a.free(committed);
    const rendered = try renderBySpecifier(a, specifier);
    defer a.free(rendered);

    testing.expectEqualStrings(committed, rendered) catch |err| {
        std.debug.print("\nmodule spec drift: {s} ({s})\n", .{ specifier, spec_path });
        return err;
    };
}

test "cache renders byte-identical to its committed spec" {
    // Before the files were generated, cache and sql were the only two whose
    // sole drift from their bindings was the lost `params` field. They were
    // checked with `params` stripped against the hand-written files then, which
    // is what proved the renderer's formatting, indentation, key order,
    // non-empty requiredCapabilities, contractExtractions with an omitted
    // argPosition, failureSeverity, and bare-string law rendering. That
    // evidence is recorded in the B3 plan, section 6, finding 6. Now that the
    // files are generated this is a plain byte comparison, the same thing
    // `module-spec-render --check` enforces outside the test suite.
    try expectMatchesCommitted(testing.allocator, "zttp:cache");
}

test "sql renders byte-identical to its committed spec" {
    try expectMatchesCommitted(testing.allocator, "zttp:sql");
}

test "renders every builtin module without error" {
    // Cheap total-coverage check: the per-module tests above pin bytes, this
    // one proves no binding trips an assertion or an unhandled variant.
    const a = testing.allocator;
    for (builtin_modules.builtins, builtin_modules.builtin_governance_entries) |binding, gov| {
        const out = try renderModuleSpec(a, binding, gov.module_path);
        defer a.free(out);
        try testing.expect(out.len > 0);
        try testing.expect(std.mem.endsWith(u8, out, "}\n"));
        // Must parse as JSON: formatting bugs that produce a trailing comma or
        // an unbalanced brace fail here rather than in the drift gate.
        const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
        parsed.deinit();
    }
}

test "renders the four optional export fields only when present" {
    const a = testing.allocator;

    // params: only websocket declared them in the committed files, but every
    // binding has them, so check a module that had none in JSON and does in Zig.
    const env = try renderBySpecifier(a, "zttp:env");
    defer a.free(env);
    try testing.expect(std.mem.indexOf(u8, env, "\"params\": [") != null);

    // laws, both shapes: crypto has "pure" and inverseOf, auth has absorbing.
    const crypto = try renderBySpecifier(a, "zttp:crypto");
    defer a.free(crypto);
    try testing.expect(std.mem.indexOf(u8, crypto, "\"pure\"") != null);
    try testing.expect(std.mem.indexOf(u8, crypto, "\"inverseOf\": \"base64Decode\"") != null);

    const auth = try renderBySpecifier(a, "zttp:auth");
    defer a.free(auth);
    try testing.expect(std.mem.indexOf(u8, auth, "\"absorbing\": {") != null);
    try testing.expect(std.mem.indexOf(u8, auth, "\"argumentShape\": \"empty_string_literal\"") != null);
    try testing.expect(std.mem.indexOf(u8, auth, "\"failureSeverity\": \"critical\"") != null);

    // argPosition is emitted when non-zero and omitted when zero. durable's
    // `signal` has one extraction of each.
    const durable = try renderBySpecifier(a, "zttp:durable");
    defer a.free(durable);
    try testing.expect(std.mem.indexOf(u8, durable, "\"argPosition\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, durable, "\"argPosition\": 0") == null);

    // flag_only is never projected, whatever the binding says.
    for (builtin_modules.builtins, builtin_modules.builtin_governance_entries) |binding, gov| {
        const out = try renderModuleSpec(a, binding, gov.module_path);
        defer a.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "flagOnly") == null);
        try testing.expect(std.mem.indexOf(u8, out, "flag_only") == null);
    }
}

test "empty required capabilities render inline" {
    const a = testing.allocator;
    const validate = try renderBySpecifier(a, "zttp:validate");
    defer a.free(validate);
    try testing.expect(std.mem.indexOf(u8, validate, "\"requiredCapabilities\": [],") != null);
}

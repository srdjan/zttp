//! Application-invariant drift and evidence gate.
//!
//! This compares independent definitions. The acceptance kernel owns the closed
//! operation catalog and the closed kind catalog. The compiler maps imports to
//! its row numbers. The native module owns the exports and effects. The
//! bytecode observer owns the final-code names. The runtime binds the adapter
//! member of the executable graph. The authoring command renders the kind
//! catalog for a developer. No producer summary is used as proof that these
//! surfaces agree.
//!
//! A surface that is data is imported and compared as a value: a typed import
//! cannot be misparsed, so the predecessor's "unparsed token" guard has no
//! counterpart here. A surface that is code is text-scanned, because Zig has no
//! regex and the shape of a call site is not available as a value.
//!
//! Every invocation also runs one in-memory mutation probe per independent
//! input. The probes mutate a copy held in this process and re-validate. They
//! never touch the working tree: the build step that runs this gate also
//! depends on five compiled test suites, so deleting an input on disk would
//! fail their compile and the nonzero exit would come from the Zig compiler
//! rather than from any comparison made here.
//!
//! Each probe names the check it expects to reject it. A gate whose comparison
//! is vacuous accepts its inputs and its mutations alike, and a probe that only
//! asserts "something failed" cannot tell that apart from an unrelated failure
//! two checks earlier.

const std = @import("std");
const zts = @import("zts");
const pcc = @import("zttp_proof_checker");
const author = @import("invariant_author.zig");
const invariant_config = @import("invariant_config.zig");

const invariant = pcc.invariant;

/// The protected module. Four surfaces name it independently - the compiler
/// resolver, the SDK binding, the linked binding, and the bytecode observer -
/// and the gate requires all four to agree with this one value.
const ledger_specifier = "zttp:ledger";

/// The proof-IR tag reserved for a ledger call, pinned on both sides of the
/// producer/consumer boundary.
const ledger_call_tag = 8;

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

/// One independently authored source the gate reads as text. `EnumArray.init`
/// below takes one field per member and supplies no default, so an input added
/// here without a path fails to compile rather than being skipped at run time.
const Input = enum {
    kernel,
    proof_system,
    compiler,
    compiler_ir,
    native,
    native_bridge,
    observer,
    producer,
    activation,
    adapter_bridge,
    runtime_install,
    artifact_graph,
    checker_tests,
    config_tests,
    author_src,
    cli_src,
    docs,
    concepts,
    build,
};

const paths = std.EnumArray(Input, []const u8).init(.{
    .kernel = "packages/proof-checker/src/invariant.zig",
    .proof_system = "packages/proof-checker/src/proof_system.zig",
    .compiler = "packages/tools/src/precompile.zig",
    .compiler_ir = "packages/zts/src/proof_ir.zig",
    .native = "packages/modules/src/data/ledger.zig",
    .native_bridge = "packages/zts/src/modules/data/ledger.zig",
    .observer = "packages/runtime/src/invariant_observer.zig",
    .producer = "packages/runtime/src/proof_certificate.zig",
    .activation = "packages/runtime/src/proof_activation.zig",
    .adapter_bridge = "packages/runtime/src/invariant_adapter.zig",
    .runtime_install = "packages/runtime/src/handler_instance.zig",
    .artifact_graph = "packages/runtime/src/artifact_graph.zig",
    .checker_tests = "packages/proof-checker/src/checker.zig",
    .config_tests = "packages/tools/src/invariant_config.zig",
    .author_src = "packages/tools/src/invariant_author.zig",
    .cli_src = "packages/runtime/src/invariant_cli.zig",
    .docs = "docs/verification.md",
    .concepts = "CONCEPTS.md",
    .build = "build.zig",
});

/// Compiled behavioral evidence. The gate proves the marker is present; the
/// build step it hangs off proves the marked test compiles and runs.
const Evidence = struct { input: Input, marker: []const u8 };

const evidence = [_]Evidence{
    .{ .input = .checker_tests, .marker = "test \"a configured invariant is checked independently from property and guard verdicts\"" },
    .{ .input = .checker_tests, .marker = "test \"missing and extra invariant witnesses reject\"" },
    .{ .input = .checker_tests, .marker = "test \"a forged invariant operation cannot borrow a real call site\"" },
    .{ .input = .artifact_graph, .marker = "test \"the inventory covers every executable and authority-bearing member\"" },
    .{ .input = .artifact_graph, .marker = "test \"an invariant specification with no linked adapter digest is refused\"" },
    .{ .input = .adapter_bridge, .marker = "test \"the linked adapter manifest digests to what the acceptance kernel expects\"" },
    .{ .input = .adapter_bridge, .marker = "test \"an adapter manifest missing a predicate row is refused\"" },
    .{ .input = .native, .marker = "test \"posting groups require exact zero sum using i128 accumulation\"" },
    .{ .input = .config_tests, .marker = "test \"confirmed invariant JSON canonicalizes currencies and rejects weakened templates\"" },
    .{ .input = .author_src, .marker = "test \"the kind listing names every catalog member with its required status\"" },
    .{ .input = .author_src, .marker = "test \"a sentence with no kind selection produces no candidate\"" },
    .{ .input = .author_src, .marker = "test \"an advisory naming a different template conflicts and blocks the candidate\"" },
};

// ---------------------------------------------------------------------------
// Verdicts
// ---------------------------------------------------------------------------

/// Every way the gate can reject. A probe names one of these, so a mutation
/// caught by an unrelated check is reported as a probe failure rather than as
/// evidence that the intended comparison works.
const Check = enum {
    none,
    missing_source,
    empty_source,
    catalog_floor,
    catalog_duplicate_operation,
    compiler_resolver_missing,
    compiler_module,
    compiler_rows_empty,
    compiler_duplicate_name,
    compiler_index_mismatch,
    native_specifier_missing,
    native_specifier,
    native_binding_missing,
    native_exports_empty,
    native_duplicate_export,
    native_effect_mismatch,
    observer_rows_empty,
    observer_name_mismatch,
    observer_operation_mismatch,
    proof_system_tag,
    compiler_ir_tag,
    producer_tag_map,
    producer_catalog_derivation,
    kernel_adapter_declaration,
    kernel_adapter_digest_derivation,
    kernel_adapter_digest_empty,
    bridge_not_adapted,
    graph_adapter_member,
    native_post_dispatch,
    native_baseline_dispatch,
    native_manifest_derivation,
    native_manifest_empty,
    adapter_manifest_mismatch,
    graph_adapter_from_kernel,
    producer_adapter_binding,
    activation_adapter_binding,
    bridge_reads_native,
    adapter_value_copied,
    install_order,
    docs_block_missing,
    docs_rows_empty,
    docs_catalog_mismatch,
    docs_schema_statement,
    concepts_entry,
    missing_evidence,
    kind_table_floor,
    kind_description_empty,
    kind_predicate_version,
    kind_ordinal_range,
    kind_ordinal_duplicate,
    kind_ordinal_mismatch,
    config_kind_missing,
    config_accepts_unknown_kind,
    config_schema_closure,
    config_schema_coverage,
    schema_v1_moved,
    schema_versions_not_distinct,
    v1_digest_domain_changed,
    v2_digest_domain_shared,
    docs_invariant_schema_statement,
    authoring_output_mismatch,
    cli_delegates_listing,
    build_step_missing,
    build_side_effects,
    build_evidence_dependencies,
    build_replaced_gate,
};

const Rejection = error{Rejected};

/// The one rejection the gate carries out of `validate`. The message is
/// formatted into a fixed buffer so a rejection path never allocates.
const Gate = struct {
    check: Check = .none,
    buffer: [768]u8 = undefined,
    length: usize = 0,

    fn reject(self: *Gate, check: Check, comptime fmt: []const u8, args: anytype) Rejection {
        self.check = check;
        const written = std.fmt.bufPrint(&self.buffer, fmt, args) catch self.buffer[0..0];
        self.length = written.len;
        return error.Rejected;
    }

    fn message(self: *const Gate) []const u8 {
        return self.buffer[0..self.length];
    }
};

// ---------------------------------------------------------------------------
// The model: imported values plus the text of every code surface
// ---------------------------------------------------------------------------

const CatalogRow = struct {
    operation: []const u8,
    sink: []const u8,
    impl_id: u32,
    writes: bool,
};

const KindRow = struct {
    name: []const u8,
    description: []const u8,
    wire_ordinal: u16,
    predicate_version: u16,
    required: bool,
    applies_to_writes: bool,
};

const NativeExport = struct { name: []const u8, effect: []const u8 };

/// One predicate row of an adapter manifest, in the gate's own type. The
/// linked adapter and the acceptance kernel each fill one of these, from
/// packages that do not import each other.
const ManifestRow = struct { kind_ordinal: u16, predicate_version: u16 };

const ManifestView = struct {
    identity: []const u8,
    store_schema_version: i64,
    predicates: []ManifestRow,
    exports: [][]const u8,
};

/// What the confirmed-template boundary does with one kind name, measured by
/// running its parser rather than by scanning its source for a string literal.
/// A text proxy would stop meaning anything the day that file resolves the name
/// through the enum instead of comparing a literal, and it would stop meaning
/// anything quietly.
const ConfigAcceptance = struct {
    name: []const u8,
    /// The wire schema the offered document declared.
    schema: u16,
    accepted: bool,
    /// The error name when the boundary refused, otherwise empty.
    failure: []const u8,
};

/// Whether the boundary refused a kind the catalog does not name, per schema.
const UnknownRefusal = struct { schema: u16, refused: bool };

/// Whether each wire schema's digest lands where it must, measured against the
/// gate's own copy of the schema 1 domain below.
const DigestDomains = struct {
    /// Schema 1 bytes still hash under the schema 1 domain. Deployed artifacts
    /// and existing ledger stores are bound to exactly those digests.
    v1_preserved: bool = false,
    /// Schema 2 bytes do not. A shared domain would let a schema 2 document
    /// answer to a commitment made over schema 1 bytes.
    v2_separated: bool = false,
};

/// A name the closed catalog must never grow.
const unknown_kind_name = "gate_probe_kind_the_catalog_does_not_name";

/// The gate's own copy of the schema 1 digest domain. The kernel's constant is
/// deliberately not read here: a change to it must surface as a disagreement
/// between two independent statements rather than as both moving together.
const v1_digest_domain_literal = "zttp-invariant-spec-v1";

const Model = struct {
    text: std.EnumArray(Input, []const u8),
    catalog: []CatalogRow,
    kinds: []KindRow,
    native_exports: []NativeExport,
    native_binding_found: bool,
    /// What `zttp invariant list` prints, rendered through the same function
    /// the CLI calls. Compared against `kinds`, never derived from it.
    authoring: []const u8,
    /// One measured verdict per catalog kind per wire schema from the
    /// confirmed-template parser, and one per schema for a kind the catalog
    /// omits.
    config_acceptance: []ConfigAcceptance,
    config_unknown_refusals: []UnknownRefusal,
    /// The two wire schemas, imported as values.
    schema_version: u16,
    schema_version_v2: u16,
    digest_domains: DigestDomains,
    adapter_digest: [32]u8,
    /// The manifest of the ledger adapter this gate binary linked, imported as
    /// a value through `zts`. It is the producer's side of the adapter member.
    native_manifest: ManifestView,
    /// The manifest the acceptance kernel expects, imported as a value. It is
    /// the consumer's side. The gate hashes both with the kernel's encoder and
    /// compares, which is the same comparison acceptance makes.
    expected_manifest: ManifestView,
};

fn effectFor(writes: bool) []const u8 {
    return if (writes) "write" else "read";
}

fn buildCatalog(arena: std.mem.Allocator) ![]CatalogRow {
    const rows = try arena.alloc(CatalogRow, invariant.catalog.len);
    errdefer arena.free(rows);
    for (invariant.catalog, 0..) |entry, index| {
        rows[index] = .{
            .operation = @tagName(entry.operation),
            .sink = @tagName(entry.sink),
            .impl_id = entry.impl_id,
            .writes = entry.writes,
        };
    }
    return rows;
}

fn buildKinds(arena: std.mem.Allocator) ![]KindRow {
    const fields = @typeInfo(invariant.Kind).@"enum".fields;
    const rows = try arena.alloc(KindRow, fields.len);
    errdefer arena.free(rows);
    inline for (fields, 0..) |field, index| {
        const kind: invariant.Kind = @enumFromInt(field.value);
        const info = invariant.kindInfo(kind);
        rows[index] = .{
            .name = field.name,
            .description = info.description,
            .wire_ordinal = info.wire_ordinal,
            .predicate_version = info.predicate_version,
            .required = info.required,
            .applies_to_writes = info.applies_to_writes,
        };
    }
    return rows;
}

fn buildNativeExports(arena: std.mem.Allocator, found: *bool) ![]NativeExport {
    found.* = false;
    for (zts.builtinModules) |binding| {
        if (!std.mem.eql(u8, binding.specifier, ledger_specifier)) continue;
        found.* = true;
        const rows = try arena.alloc(NativeExport, binding.exports.len);
        errdefer arena.free(rows);
        for (binding.exports, 0..) |item, index| {
            rows[index] = .{ .name = item.name, .effect = @tagName(item.effect) };
        }
        return rows;
    }
    return try arena.alloc(NativeExport, 0);
}

fn buildNativeManifest(arena: std.mem.Allocator) !ManifestView {
    const source = zts.modules.ledger.adapter_manifest;
    const rows = try arena.alloc(ManifestRow, source.predicates.len);
    errdefer arena.free(rows);
    for (source.predicates, 0..) |row, index| {
        rows[index] = .{ .kind_ordinal = row.kind_ordinal, .predicate_version = row.predicate_version };
    }
    const names = try arena.alloc([]const u8, source.exports.len);
    errdefer arena.free(names);
    for (source.exports, 0..) |name, index| names[index] = name;
    return .{
        .identity = source.identity,
        .store_schema_version = source.store_schema_version,
        .predicates = rows,
        .exports = names,
    };
}

fn buildExpectedManifest(arena: std.mem.Allocator) !ManifestView {
    const source = invariant.expected_adapter_manifest;
    const rows = try arena.alloc(ManifestRow, source.predicates.len);
    errdefer arena.free(rows);
    for (source.predicates, 0..) |row, index| {
        rows[index] = .{ .kind_ordinal = row.kind_ordinal, .predicate_version = row.predicate_version };
    }
    const names = try arena.alloc([]const u8, source.exports.len);
    errdefer arena.free(names);
    for (source.exports, 0..) |name, index| names[index] = name;
    return .{
        .identity = source.identity,
        .store_schema_version = source.store_schema_version,
        .predicates = rows,
        .exports = names,
    };
}

/// Hash one view with the kernel's encoder. The gate converts back into the
/// kernel's type here rather than keeping the kernel's value around, so a
/// mutation applied to the view reaches the digest.
fn manifestDigest(arena: std.mem.Allocator, view: ManifestView) ![32]u8 {
    const rows = try arena.alloc(invariant.AdapterPredicate, view.predicates.len);
    errdefer arena.free(rows);
    for (view.predicates, 0..) |row, index| {
        rows[index] = .{ .kind_ordinal = row.kind_ordinal, .predicate_version = row.predicate_version };
    }
    return invariant.adapterManifestDigest(.{
        .identity = view.identity,
        .store_schema_version = view.store_schema_version,
        .predicates = rows,
        .exports = view.exports,
    });
}

/// The smallest schema 1 document the confirmed-template boundary can accept,
/// naming one kind in the header field that schema owns. Every other field is
/// held constant so the kind is the variable.
fn confirmedTemplate(arena: std.mem.Allocator, kind_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"version\":{d},\"kind\":\"{s}\",\"ledger\":\"gate\",\"currencies\":[{{\"code\":\"USD\",\"scale\":2}}]}}",
        .{ invariant.schema_version, kind_name },
    );
}

/// The same document under schema 2, which names its kinds in a record list.
/// Every kind the catalog marks required joins the named one, because a set
/// missing one of those is refused whatever else it names, and the measurement
/// here is about the named kind rather than about the required set.
fn confirmedTemplateV2(arena: std.mem.Allocator, kind_name: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(arena);
    errdefer writer.deinit();
    const out = &writer.writer;
    try out.print(
        "{{\"version\":{d},\"ledger\":\"gate\",\"currencies\":[{{\"code\":\"USD\",\"scale\":2}}],\"kinds\":[{{\"kind\":\"{s}\"}}",
        .{ invariant.schema_version_v2, kind_name },
    );
    for (std.enums.values(invariant.Kind)) |kind| {
        if (!invariant.kindInfo(kind).required) continue;
        if (std.mem.eql(u8, @tagName(kind), kind_name)) continue;
        try out.print(",{{\"kind\":\"{s}\"}}", .{@tagName(kind)});
    }
    try out.writeAll("]}");
    return writer.written();
}

fn templateFor(arena: std.mem.Allocator, schema: u16, kind_name: []const u8) ![]u8 {
    if (schema == invariant.schema_version_v2) return confirmedTemplateV2(arena, kind_name);
    return confirmedTemplate(arena, kind_name);
}

const measured_schemas = [_]u16{ invariant.schema_version, invariant.schema_version_v2 };

/// Whether the authoring boundary must author `required` under `schema`.
///
/// Schema 2 carries a record list, so it authors every catalog kind. Schema 1
/// has room for one kind in its header and its decoder admits only the required
/// one, so the boundary must refuse the rest there rather than emit bytes a
/// consumer would reject. The two statements are settled here, in one place,
/// because a gate that only demanded acceptance would turn red the day the
/// catalog grows and offer no way to tell a closed schema from a broken one.
fn mustAuthor(schema: u16, required: bool) bool {
    if (schema == invariant.schema_version) return required;
    return true;
}

/// The refusal a closed schema must give. Any other error means the boundary
/// refused for a reason the gate did not ask about.
const closed_schema_failure = "UnsupportedInvariantKind";

fn measureConfigAcceptance(arena: std.mem.Allocator, kinds: []const KindRow) ![]ConfigAcceptance {
    const rows = try arena.alloc(ConfigAcceptance, kinds.len * measured_schemas.len);
    errdefer arena.free(rows);
    var index: usize = 0;
    for (kinds) |kind| {
        for (measured_schemas) |schema| {
            const document = try templateFor(arena, schema, kind.name);
            defer arena.free(document);
            if (invariant_config.parse(arena, document)) |bytes| {
                arena.free(bytes);
                rows[index] = .{ .name = kind.name, .schema = schema, .accepted = true, .failure = "" };
            } else |err| {
                rows[index] = .{ .name = kind.name, .schema = schema, .accepted = false, .failure = @errorName(err) };
            }
            index += 1;
        }
    }
    return rows;
}

fn measureConfigRejectsUnknown(arena: std.mem.Allocator) ![]UnknownRefusal {
    const rows = try arena.alloc(UnknownRefusal, measured_schemas.len);
    errdefer arena.free(rows);
    for (measured_schemas, 0..) |schema, index| {
        const document = try templateFor(arena, schema, unknown_kind_name);
        defer arena.free(document);
        if (invariant_config.parse(arena, document)) |bytes| {
            arena.free(bytes);
            rows[index] = .{ .schema = schema, .refused = false };
        } else |err| {
            rows[index] = .{ .schema = schema, .refused = err == error.UnsupportedInvariantKind };
        }
    }
    return rows;
}

fn hashUnderV1Domain(bytes: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(v1_digest_domain_literal);
    hasher.update(bytes);
    return hasher.finalResult();
}

/// Hash one document per schema, produced by the authoring boundary, and ask
/// where each digest lands relative to the schema 1 domain stated above.
fn measureDigestDomains(arena: std.mem.Allocator, kinds: []const KindRow) !DigestDomains {
    var measured: DigestDomains = .{};
    if (kinds.len == 0) return measured;
    const name = kinds[0].name;

    const v1_document = try confirmedTemplate(arena, name);
    defer arena.free(v1_document);
    if (invariant_config.parse(arena, v1_document)) |bytes| {
        defer arena.free(bytes);
        measured.v1_preserved = std.mem.eql(u8, &invariant.digest(bytes), &hashUnderV1Domain(bytes));
    } else |_| {}

    const v2_document = try confirmedTemplateV2(arena, name);
    defer arena.free(v2_document);
    if (invariant_config.parse(arena, v2_document)) |bytes| {
        defer arena.free(bytes);
        measured.v2_separated = !std.mem.eql(u8, &invariant.digest(bytes), &hashUnderV1Domain(bytes));
    } else |_| {}

    return measured;
}

fn renderAuthoring(arena: std.mem.Allocator) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(arena);
    errdefer writer.deinit();
    try author.renderList(&writer.writer);
    return writer.written();
}

// ---------------------------------------------------------------------------
// Text helpers. There is no regex in Zig, so every scan below is an explicit
// search over bytes or lines.
// ---------------------------------------------------------------------------

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, cursor, needle)) |found| {
        count += 1;
        cursor = found + needle.len;
    }
    return count;
}

fn quotedAt(text: []const u8, start: usize) ?[]const u8 {
    const open = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, text, open + 1, '"') orelse return null;
    return text[open + 1 .. close];
}

fn identifierAt(text: []const u8, start: usize) []const u8 {
    var cursor = start;
    while (cursor < text.len and (std.ascii.isAlphanumeric(text[cursor]) or text[cursor] == '_')) {
        cursor += 1;
    }
    return text[start..cursor];
}

fn unsignedAfter(text: []const u8, marker: []const u8, start: usize) ?u32 {
    const at = std.mem.indexOfPos(u8, text, start, marker) orelse return null;
    var cursor = at + marker.len;
    while (cursor < text.len and text[cursor] == ' ') cursor += 1;
    const begin = cursor;
    while (cursor < text.len and std.ascii.isDigit(text[cursor])) cursor += 1;
    if (cursor == begin) return null;
    return std.fmt.parseInt(u32, text[begin..cursor], 10) catch null;
}

/// The body of the first function whose signature contains `signature`,
/// delimited by brace depth. Every body this gate reads is Zig without a brace
/// inside a string or comment.
fn functionBody(text: []const u8, signature: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, signature) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, text, at, '{') orelse return null;
    var depth: usize = 0;
    var cursor = open;
    while (cursor < text.len) : (cursor += 1) {
        switch (text[cursor]) {
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return text[open + 1 .. cursor];
            },
            else => {},
        }
    }
    return null;
}

/// True for a kernel declaration a producer must never copy.
///
/// An adapter *value* is one: identity, store schema, the expected manifest,
/// the expected digest, the kind table the manifest is derived from. Copying
/// one puts the consumer's own constant on both sides of the comparison, which
/// is the failure this whole surface exists to prevent.
///
/// A type and the encoder are not values. Both sides must name one type and
/// one encoding, or two digests are not comparable at all, so `AdapterManifest`,
/// `AdapterPredicate` and `adapterManifestDigest` are excluded. So is the
/// specification surface (`decode`, `digest`), which is a function of artifact
/// bytes rather than a constant.
fn isForbiddenKernelRead(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.ascii.isUpper(name[0])) return false;
    if (std.mem.eql(u8, name, "adapterManifestDigest")) return false;
    if (std.mem.indexOf(u8, name, "adapter") != null) return true;
    return std.mem.eql(u8, name, "kind_table") or std.mem.eql(u8, name, "kindInfo");
}

const invariant_decls = @typeInfo(invariant).@"struct".decls;

const forbidden_kernel_read_count = blk: {
    var found: usize = 0;
    for (invariant_decls) |decl| {
        if (isForbiddenKernelRead(decl.name)) found += 1;
    }
    break :blk found;
};

/// The names a producer surface may not mention, read out of the kernel's own
/// namespace rather than listed here. A constant added to the kernel joins
/// this set without anybody remembering to add it, which is the difference
/// between a check that catches the next spelling and one that catches only
/// the spelling it was written against.
const forbidden_kernel_reads: [forbidden_kernel_read_count][]const u8 = blk: {
    var names: [forbidden_kernel_read_count][]const u8 = undefined;
    var found: usize = 0;
    for (invariant_decls) |decl| {
        if (!isForbiddenKernelRead(decl.name)) continue;
        names[found] = decl.name;
        found += 1;
    }
    const frozen = names;
    break :blk frozen;
};

/// The first forbidden kernel name `text` mentions, or null.
fn copiedKernelValue(text: []const u8) ?[]const u8 {
    for (forbidden_kernel_reads) |name| {
        if (std.mem.indexOf(u8, text, name) != null) return name;
    }
    return null;
}

/// The same text with every `//` comment blanked out.
///
/// A check of the form "this identifier must not appear" is otherwise tripped
/// by a comment explaining why it must not appear, which teaches the next
/// author to delete the explanation. Blanking rather than deleting keeps the
/// byte length, so a later offset still lines up with the original.
fn withoutComments(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try arena.dupe(u8, text);
    errdefer arena.free(out);
    var cursor: usize = 0;
    while (cursor + 1 < out.len) : (cursor += 1) {
        if (out[cursor] != '/' or out[cursor + 1] != '/') continue;
        while (cursor < out.len and out[cursor] != '\n') : (cursor += 1) out[cursor] = ' ';
    }
    return out;
}

/// The top-level arguments of the call whose open parenthesis is at `open`.
fn splitArguments(arena: std.mem.Allocator, text: []const u8, open: usize) !?[][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(arena);
    var depth: usize = 0;
    var start = open + 1;
    var cursor = open;
    while (cursor < text.len) : (cursor += 1) {
        switch (text[cursor]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) {
                    try list.append(arena, std.mem.trim(u8, text[start..cursor], " \t\r\n"));
                    return try list.toOwnedSlice(arena);
                }
            },
            ',' => if (depth == 1) {
                try list.append(arena, std.mem.trim(u8, text[start..cursor], " \t\r\n"));
                start = cursor + 1;
            },
            else => {},
        }
    }
    return null;
}

const CompilerRow = struct { name: []const u8, index: u32 };

fn compilerRows(arena: std.mem.Allocator, body: []const u8) ![]CompilerRow {
    var list: std.ArrayList(CompilerRow) = .empty;
    errdefer list.deinit(arena);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "imported.name,") orelse continue;
        const name = quotedAt(line, at) orelse continue;
        const index = unsignedAfter(line, "return", at) orelse continue;
        try list.append(arena, .{ .name = name, .index = index });
    }
    return try list.toOwnedSlice(arena);
}

const ObserverRow = struct { atom: []const u8, operation: []const u8 };

fn observerRows(arena: std.mem.Allocator, text: []const u8) ![]ObserverRow {
    var list: std.ArrayList(ObserverRow) = .empty;
    errdefer list.deinit(arena);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "\"" ++ ledger_specifier ++ "#") orelse continue;
        const atom = quotedAt(line, at) orelse continue;
        const tag_at = std.mem.indexOfPos(u8, line, at, "return .") orelse continue;
        const operation = identifierAt(line, tag_at + "return .".len);
        if (operation.len == 0) continue;
        try list.append(arena, .{ .atom = atom, .operation = operation });
    }
    return try list.toOwnedSlice(arena);
}

const docs_catalog_open = "<!-- application-invariants: catalog -->";
const docs_catalog_close = "<!-- application-invariants: evidence -->";

fn docsRows(arena: std.mem.Allocator, text: []const u8) !?[][]const u8 {
    if (countOccurrences(text, docs_catalog_open) != 1) return null;
    if (countOccurrences(text, docs_catalog_close) != 1) return null;
    const open = std.mem.indexOf(u8, text, docs_catalog_open) orelse return null;
    const close = std.mem.indexOfPos(u8, text, open, docs_catalog_close) orelse return null;
    const block = text[open + docs_catalog_open.len .. close];
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(arena);
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "- `")) continue;
        if (!std.mem.endsWith(u8, line, "`")) continue;
        if (line.len <= 4) continue;
        try list.append(arena, line[3 .. line.len - 1]);
    }
    return try list.toOwnedSlice(arena);
}

/// The single value assigned to a `ledger_call` tag, or null when the text
/// holds no numeric assignment or more than one. Two assignments are ambiguous,
/// not a pass on whichever comes first.
fn ledgerCallTag(text: []const u8) ?u32 {
    const marker = "ledger_call";
    var found: ?u32 = null;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, text, cursor, marker)) |at| {
        cursor = at + marker.len;
        var scan = cursor;
        while (scan < text.len and text[scan] == ' ') scan += 1;
        if (scan >= text.len or text[scan] != '=') continue;
        scan += 1;
        // `.ledger_call => ...` is a switch prong, not an assignment.
        if (scan < text.len and text[scan] == '>') continue;
        while (scan < text.len and text[scan] == ' ') scan += 1;
        const begin = scan;
        while (scan < text.len and std.ascii.isDigit(text[scan])) scan += 1;
        if (scan == begin) continue;
        const value = std.fmt.parseInt(u32, text[begin..scan], 10) catch continue;
        if (found != null) return null;
        found = value;
    }
    return found;
}

/// Every `pub const` in the kernel whose name reads as the expected native
/// adapter. The name is not pinned: today it is `adapter_identity`, and the
/// digest below is required to be derived from whichever one of these it names.
fn adapterDeclarations(arena: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(arena);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "pub const ")) continue;
        const name = identifierAt(line, "pub const ".len);
        if (name.len == 0) continue;
        const adapter = std.mem.indexOf(u8, name, "adapter") != null;
        const manifest = std.mem.indexOf(u8, name, "manifest") != null;
        if (!adapter and !manifest) continue;
        try list.append(arena, name);
    }
    return try list.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

fn validate(arena: std.mem.Allocator, gate: *Gate, model: Model) !void {
    for (std.enums.values(Input)) |input| {
        if (model.text.get(input).len == 0) {
            return gate.reject(.empty_source, "empty {s} source: {s}", .{ @tagName(input), paths.get(input) });
        }
    }

    // --- the closed operation catalog, imported as a value -------------------
    if (model.catalog.len < 2) {
        return gate.reject(.catalog_floor, "kernel catalog has {d} rows, expected at least 2", .{model.catalog.len});
    }
    for (model.catalog, 0..) |row, index| {
        for (model.catalog[index + 1 ..]) |other| {
            if (std.mem.eql(u8, row.operation, other.operation)) {
                return gate.reject(.catalog_duplicate_operation, "kernel catalog names '{s}' twice", .{row.operation});
            }
        }
    }

    // --- the compiler's import-to-row map ------------------------------------
    //
    // "Exactly one" rather than "the first". A second definition of a surface
    // the gate reads is drift in itself, and reading the first of two silently
    // picks a side.
    if (countOccurrences(model.text.get(.compiler), "fn resolveLedger(") != 1) {
        return gate.reject(.compiler_resolver_missing, "{s} has no single resolveLedger definition", .{paths.get(.compiler)});
    }
    const resolver = functionBody(model.text.get(.compiler), "fn resolveLedger(") orelse
        return gate.reject(.compiler_resolver_missing, "compiler has no resolveLedger body in {s}", .{paths.get(.compiler)});
    if (countOccurrences(resolver, "imported.module,") != 1) {
        return gate.reject(.compiler_module, "compiler resolver names no single module", .{});
    }
    const resolver_module = blk: {
        const at = std.mem.indexOf(u8, resolver, "imported.module,") orelse
            return gate.reject(.compiler_module, "compiler resolver names no module", .{});
        break :blk quotedAt(resolver, at) orelse
            return gate.reject(.compiler_module, "compiler resolver names no module", .{});
    };
    if (!std.mem.eql(u8, resolver_module, ledger_specifier)) {
        return gate.reject(.compiler_module, "compiler resolves invariant calls from '{s}', not '{s}'", .{ resolver_module, ledger_specifier });
    }
    const compiler_rows = try compilerRows(arena, resolver);
    if (compiler_rows.len == 0) {
        return gate.reject(.compiler_rows_empty, "compiler ledger resolver is empty", .{});
    }
    for (compiler_rows, 0..) |row, index| {
        for (compiler_rows[index + 1 ..]) |other| {
            if (std.mem.eql(u8, row.name, other.name)) {
                return gate.reject(.compiler_duplicate_name, "compiler resolver names '{s}' twice", .{row.name});
            }
        }
    }
    if (compiler_rows.len != model.catalog.len) {
        return gate.reject(.compiler_index_mismatch, "compiler has {d} rows, kernel catalog has {d}", .{ compiler_rows.len, model.catalog.len });
    }
    for (model.catalog, 0..) |row, index| {
        var matched = false;
        for (compiler_rows) |mapped| {
            if (!std.mem.eql(u8, mapped.name, row.operation)) continue;
            matched = true;
            if (mapped.index != index) {
                return gate.reject(.compiler_index_mismatch, "compiler maps '{s}' to row {d}, kernel catalog row is {d}", .{ row.operation, mapped.index, index });
            }
        }
        if (!matched) {
            return gate.reject(.compiler_index_mismatch, "compiler resolver does not map kernel operation '{s}'", .{row.operation});
        }
    }

    // --- the native module's declared specifier, exports and effects ---------
    const native_text = model.text.get(.native);
    if (countOccurrences(native_text, ".specifier = \"") != 1) {
        return gate.reject(.native_specifier_missing, "{s} declares no single module specifier", .{paths.get(.native)});
    }
    const declared_specifier = blk: {
        const at = std.mem.indexOf(u8, native_text, ".specifier = \"") orelse unreachable;
        break :blk quotedAt(native_text, at) orelse
            return gate.reject(.native_specifier_missing, "{s} declares no single module specifier", .{paths.get(.native)});
    };
    if (!std.mem.eql(u8, declared_specifier, ledger_specifier)) {
        return gate.reject(.native_specifier, "native module specifier is '{s}', not '{s}'", .{ declared_specifier, ledger_specifier });
    }
    if (!model.native_binding_found) {
        return gate.reject(.native_binding_missing, "no linked virtual module declares the specifier '{s}'", .{ledger_specifier});
    }
    if (model.native_exports.len == 0) {
        return gate.reject(.native_exports_empty, "native ledger export set is empty", .{});
    }
    for (model.native_exports, 0..) |item, index| {
        for (model.native_exports[index + 1 ..]) |other| {
            if (std.mem.eql(u8, item.name, other.name)) {
                return gate.reject(.native_duplicate_export, "native ledger exports '{s}' twice", .{item.name});
            }
        }
    }
    if (model.native_exports.len != model.catalog.len) {
        return gate.reject(.native_effect_mismatch, "native module exports {d} operations, kernel catalog has {d}", .{ model.native_exports.len, model.catalog.len });
    }
    for (model.catalog) |row| {
        var matched = false;
        for (model.native_exports) |item| {
            if (!std.mem.eql(u8, item.name, row.operation)) continue;
            matched = true;
            if (!std.mem.eql(u8, item.effect, effectFor(row.writes))) {
                return gate.reject(.native_effect_mismatch, "native export '{s}' has effect '{s}', kernel catalog says '{s}'", .{ row.operation, item.effect, effectFor(row.writes) });
            }
        }
        if (!matched) {
            return gate.reject(.native_effect_mismatch, "native module does not export kernel operation '{s}'", .{row.operation});
        }
    }

    // --- the bytecode observer's final-code names ----------------------------
    const observer_rows = try observerRows(arena, model.text.get(.observer));
    if (observer_rows.len == 0) {
        return gate.reject(.observer_rows_empty, "bytecode observer ledger set is empty", .{});
    }
    for (observer_rows) |row| {
        const hash = std.mem.indexOfScalar(u8, row.atom, '#') orelse
            return gate.reject(.observer_name_mismatch, "observer atom '{s}' has no operation suffix", .{row.atom});
        const encoded = row.atom[hash + 1 ..];
        if (!std.mem.eql(u8, row.atom[0..hash], ledger_specifier)) {
            return gate.reject(.observer_name_mismatch, "observer atom '{s}' is not a '{s}' atom", .{ row.atom, ledger_specifier });
        }
        if (!std.mem.eql(u8, encoded, row.operation)) {
            return gate.reject(.observer_name_mismatch, "observer maps '{s}' to operation '{s}'", .{ encoded, row.operation });
        }
    }
    if (observer_rows.len != model.catalog.len) {
        return gate.reject(.observer_operation_mismatch, "observer knows {d} operations, kernel catalog has {d}", .{ observer_rows.len, model.catalog.len });
    }
    for (model.catalog) |row| {
        var matched = false;
        for (observer_rows) |observed| {
            if (std.mem.eql(u8, observed.operation, row.operation)) matched = true;
        }
        if (!matched) {
            return gate.reject(.observer_operation_mismatch, "observer does not decode kernel operation '{s}'", .{row.operation});
        }
    }

    // --- the proof-IR tag, pinned on both sides ------------------------------
    //
    // Find the tag first, then read its value. Counting the literal
    // `ledger_call = 8` instead would accept a file holding both an 8 and a 9 -
    // a second tag enum mid-migration - while still reporting "the tag is 8".
    const kernel_tag = ledgerCallTag(model.text.get(.proof_system)) orelse
        return gate.reject(.proof_system_tag, "{s} has no single numeric ledger_call tag", .{paths.get(.proof_system)});
    if (kernel_tag != ledger_call_tag) {
        return gate.reject(.proof_system_tag, "kernel ledger_call tag is {d}, expected {d}", .{ kernel_tag, ledger_call_tag });
    }
    const compiler_tag = ledgerCallTag(model.text.get(.compiler_ir)) orelse
        return gate.reject(.compiler_ir_tag, "{s} has no single numeric ledger_call tag", .{paths.get(.compiler_ir)});
    if (compiler_tag != ledger_call_tag) {
        return gate.reject(.compiler_ir_tag, "compiler ledger_call tag is {d}, expected {d}", .{ compiler_tag, ledger_call_tag });
    }

    // --- the producer's exhaustive mapping and catalog derivation ------------
    if (std.mem.indexOf(u8, model.text.get(.producer), ".ledger_call => .ledger_call") == null) {
        return gate.reject(.producer_tag_map, "producer no longer maps the compiler ledger_call tag exhaustively", .{});
    }
    if (std.mem.indexOf(u8, model.text.get(.producer), "pcc.invariant.catalog[") == null) {
        return gate.reject(.producer_catalog_derivation, "producer no longer derives sink and implementation identity from the kernel catalog", .{});
    }

    // --- the kernel's expected native adapter --------------------------------
    //
    // Intent, not a literal. The kernel must name the adapter it expects and
    // must build its digest from that named value instead of restating one.
    // Neither the name of the declaration nor the shape of its value is pinned.
    const kernel_text = model.text.get(.kernel);
    const declarations = try adapterDeclarations(arena, kernel_text);
    if (declarations.len == 0) {
        return gate.reject(.kernel_adapter_declaration, "kernel declares no expected native adapter value", .{});
    }
    if (countOccurrences(kernel_text, "pub fn adapterDigest(") != 1) {
        return gate.reject(.kernel_adapter_digest_derivation, "kernel has no single adapterDigest definition", .{});
    }
    const digest_body = functionBody(kernel_text, "pub fn adapterDigest(") orelse
        return gate.reject(.kernel_adapter_digest_derivation, "kernel has no adapterDigest body", .{});
    var derived = false;
    for (declarations) |name| {
        if (std.mem.indexOf(u8, digest_body, name) != null) derived = true;
    }
    if (!derived) {
        return gate.reject(.kernel_adapter_digest_derivation, "kernel adapterDigest does not read a declared expected adapter value", .{});
    }
    if (std.mem.allEqual(u8, &model.adapter_digest, 0)) {
        return gate.reject(.kernel_adapter_digest_empty, "kernel adapterDigest returns an all-zero digest", .{});
    }

    // --- the host bridge adapts the protected native binding -----------------
    if (std.mem.indexOf(u8, model.text.get(.native_bridge), "adaptModuleBinding(ledger.binding)") == null) {
        return gate.reject(.bridge_not_adapted, "native host bridge no longer adapts the protected ledger binding", .{});
    }

    // --- the executable graph carries the adapter member ---------------------
    //
    // Intent, not a literal. The graph must add an `invariant_ledger_adapter`
    // member carrying a digest. Where that digest comes from is the graph's
    // business and is expected to change.
    const graph_text = model.text.get(.artifact_graph);
    const member_needle = "collector.add(.invariant_ledger_adapter";
    if (countOccurrences(graph_text, member_needle) != 1) {
        return gate.reject(.graph_adapter_member, "artifact graph does not add exactly one invariant ledger adapter member", .{});
    }
    const member_at = std.mem.indexOf(u8, graph_text, member_needle) orelse unreachable;
    const member_open = std.mem.indexOfScalarPos(u8, graph_text, member_at, '(') orelse
        return gate.reject(.graph_adapter_member, "artifact graph adapter member is not a call", .{});
    const member_args = (try splitArguments(arena, graph_text, member_open)) orelse
        return gate.reject(.graph_adapter_member, "artifact graph adapter member call is unterminated", .{});
    if (member_args.len != 3) {
        return gate.reject(.graph_adapter_member, "artifact graph adapter member takes {d} arguments, expected 3", .{member_args.len});
    }
    if (member_args[2].len == 0 or std.mem.eql(u8, member_args[2], "undefined")) {
        return gate.reject(.graph_adapter_member, "artifact graph binds no digest to the invariant ledger adapter member", .{});
    }

    // --- the linked adapter enforces through the table it publishes ----------
    //
    // A manifest row is evidence only when the enforcement paths read it. Both
    // the write path and the store-validation path must iterate the dispatch
    // table; a call standing beside the table rather than going through it
    // would keep working after a row was removed.
    const adapter_native_text = model.text.get(.native);
    const post_body = functionBody(adapter_native_text, "fn executePost(") orelse
        return gate.reject(.native_post_dispatch, "{s} has no executePost body", .{paths.get(.native)});
    if (std.mem.indexOf(u8, post_body, "for (predicates)") == null) {
        return gate.reject(.native_post_dispatch, "the native post path does not iterate the predicate dispatch table", .{});
    }
    const baseline_body = functionBody(adapter_native_text, "fn validateBaseline(") orelse
        return gate.reject(.native_baseline_dispatch, "{s} has no validateBaseline body", .{paths.get(.native)});
    if (std.mem.indexOf(u8, baseline_body, "for (predicates)") == null) {
        return gate.reject(.native_baseline_dispatch, "the native baseline path does not iterate the predicate dispatch table", .{});
    }

    // The manifest must be derived from that table, from the store schema
    // constant, and from the binding's exports. A manifest typed out by hand
    // beside the table is a second statement that can drift from the first.
    const manifest_body = functionBody(adapter_native_text, "pub const adapter_manifest") orelse
        return gate.reject(.native_manifest_derivation, "{s} declares no adapter manifest", .{paths.get(.native)});
    if (std.mem.indexOf(u8, manifest_body, "SCHEMA_VERSION") == null) {
        return gate.reject(.native_manifest_derivation, "the native adapter manifest does not carry the store schema constant", .{});
    }
    const derived_predicates = functionBody(adapter_native_text, "const manifest_predicates") orelse
        return gate.reject(.native_manifest_derivation, "{s} derives no manifest predicate rows", .{paths.get(.native)});
    if (std.mem.indexOf(u8, derived_predicates, "for (predicates") == null) {
        return gate.reject(.native_manifest_derivation, "the native manifest rows are not derived from the dispatch table", .{});
    }
    const derived_exports = functionBody(adapter_native_text, "const manifest_exports") orelse
        return gate.reject(.native_manifest_derivation, "{s} derives no manifest export names", .{paths.get(.native)});
    if (std.mem.indexOf(u8, derived_exports, "for (binding.exports") == null) {
        return gate.reject(.native_manifest_derivation, "the native manifest exports are not derived from the binding", .{});
    }

    // --- the linked manifest against the kernel's expectation ----------------
    //
    // Two values from two packages that do not import each other, compared
    // field by field and then as digests. This is the comparison acceptance
    // makes; running it here means a drift is a build failure rather than a
    // refusal discovered on a deployment.
    const linked = model.native_manifest;
    const wanted = model.expected_manifest;
    if (linked.predicates.len == 0 or linked.exports.len == 0) {
        return gate.reject(.native_manifest_empty, "the linked ledger adapter declares {d} predicates and {d} exports", .{ linked.predicates.len, linked.exports.len });
    }
    if (!std.mem.eql(u8, linked.identity, wanted.identity)) {
        return gate.reject(.adapter_manifest_mismatch, "the linked adapter calls itself '{s}', the kernel expects '{s}'", .{ linked.identity, wanted.identity });
    }
    if (linked.store_schema_version != wanted.store_schema_version) {
        return gate.reject(.adapter_manifest_mismatch, "the linked adapter keeps store schema {d}, the kernel expects {d}", .{ linked.store_schema_version, wanted.store_schema_version });
    }
    if (linked.predicates.len != wanted.predicates.len) {
        return gate.reject(.adapter_manifest_mismatch, "the linked adapter enforces {d} predicates, the kernel expects {d}", .{ linked.predicates.len, wanted.predicates.len });
    }
    for (linked.predicates, wanted.predicates) |have, want| {
        if (have.kind_ordinal != want.kind_ordinal) {
            return gate.reject(.adapter_manifest_mismatch, "the linked adapter enforces kind ordinal {d} where the kernel expects {d}", .{ have.kind_ordinal, want.kind_ordinal });
        }
        if (have.predicate_version != want.predicate_version) {
            return gate.reject(.adapter_manifest_mismatch, "the linked adapter enforces kind {d} at predicate version {d}, the kernel expects {d}", .{ have.kind_ordinal, have.predicate_version, want.predicate_version });
        }
    }
    if (linked.exports.len != wanted.exports.len) {
        return gate.reject(.adapter_manifest_mismatch, "the linked adapter publishes {d} exports, the kernel expects {d}", .{ linked.exports.len, wanted.exports.len });
    }
    for (linked.exports, wanted.exports) |have, want| {
        if (!std.mem.eql(u8, have, want)) {
            return gate.reject(.adapter_manifest_mismatch, "the linked adapter publishes '{s}' where the kernel expects '{s}'", .{ have, want });
        }
    }
    const linked_digest = try manifestDigest(arena, linked);
    if (!std.mem.eql(u8, &linked_digest, &model.adapter_digest)) {
        return gate.reject(.adapter_manifest_mismatch, "the linked adapter manifest digests to {x}, the kernel expects {x}", .{ &linked_digest, &model.adapter_digest });
    }

    // --- the graph input comes from the linked adapter, not from the kernel --
    //
    // This is the hole the adapter manifest exists to close. If the artifact
    // graph reads the kernel's own expectation, the producer and the consumer
    // are reading one constant and the comparison holds for every artifact,
    // including one whose adapter enforces nothing.
    const graph_code = try withoutComments(arena, graph_text);
    if (countOccurrences(graph_code, "adapterDigest") != 0) {
        return gate.reject(.graph_adapter_from_kernel, "{s} reads the acceptance kernel's expected adapter digest", .{paths.get(.artifact_graph)});
    }
    const producer_text = try withoutComments(arena, model.text.get(.producer));
    if (countOccurrences(producer_text, "invariant_adapter.linkedDigest()") != 1) {
        return gate.reject(.producer_adapter_binding, "{s} does not bind the adapter member from the linked manifest exactly once", .{paths.get(.producer)});
    }
    if (std.mem.indexOf(u8, producer_text, "invariant.adapterDigest") != null) {
        return gate.reject(.producer_adapter_binding, "{s} reads the acceptance kernel's expected adapter digest", .{paths.get(.producer)});
    }
    const activation_text = try withoutComments(arena, model.text.get(.activation));
    if (countOccurrences(activation_text, "invariant_adapter.linkedDigest()") != 1) {
        return gate.reject(.activation_adapter_binding, "{s} does not bind the adapter member from the linked manifest exactly once", .{paths.get(.activation)});
    }
    if (std.mem.indexOf(u8, activation_text, "invariant.adapterDigest") != null) {
        return gate.reject(.activation_adapter_binding, "{s} reads the acceptance kernel's expected adapter digest", .{paths.get(.activation)});
    }

    // --- the bridge reads the native module, not the kernel's table ----------
    const bridge_text = try withoutComments(arena, model.text.get(.adapter_bridge));
    if (std.mem.indexOf(u8, bridge_text, "expected_adapter_manifest") != null) {
        return gate.reject(.bridge_reads_native, "{s} fills the linked manifest from the kernel's expected table", .{paths.get(.adapter_bridge)});
    }
    const linked_body = functionBody(bridge_text, "pub const linked_manifest") orelse
        return gate.reject(.bridge_reads_native, "{s} declares no linked adapter manifest", .{paths.get(.adapter_bridge)});
    if (std.mem.indexOf(u8, linked_body, "native.adapter_manifest") == null) {
        return gate.reject(.bridge_reads_native, "the linked manifest is not filled from the native module's own manifest", .{});
    }
    const linked_predicates_body = functionBody(bridge_text, "const linked_predicates") orelse
        return gate.reject(.bridge_reads_native, "{s} derives no linked predicate rows", .{paths.get(.adapter_bridge)});
    if (std.mem.indexOf(u8, linked_predicates_body, "native.adapter_manifest") == null) {
        return gate.reject(.bridge_reads_native, "the linked predicate rows are not filled from the native module's own manifest", .{});
    }

    // --- no producer surface copies a kernel adapter value -------------------
    //
    // The three checks above forbid one spelling each, and a regression that
    // reached for the next-nearest one would pass all three: a bridge that
    // filled `.identity` and `.store_schema_version` from the kernel while
    // leaving `.exports` native still names `native.adapter_manifest`, still
    // digests equal, and still compares equal field by field against a kernel
    // it copied. This is the general net, and its set is read out of the
    // kernel's namespace rather than written down.
    const copy_sites = [_]struct { input: Input, text: []const u8 }{
        .{ .input = .artifact_graph, .text = graph_code },
        .{ .input = .producer, .text = producer_text },
        .{ .input = .activation, .text = activation_text },
        // Only the two declarations that build the manifest. `require` in the
        // same file reads `adapterDigest` on purpose: that is the comparison,
        // not the value being compared.
        .{ .input = .adapter_bridge, .text = linked_body },
        .{ .input = .adapter_bridge, .text = linked_predicates_body },
    };
    for (copy_sites) |site| {
        if (copiedKernelValue(site.text)) |name| {
            return gate.reject(.adapter_value_copied, "{s} reads the kernel's '{s}' instead of deriving it from the linked adapter", .{ paths.get(site.input), name });
        }
    }

    // --- the store is never installed under an unaccepted adapter ------------
    //
    // Position, not presence. A refusal that runs after `installStore` has
    // already opened and validated a database under an adapter the consumer
    // does not accept is a refusal that came too late, and it would read as a
    // passing check in any test that only asserts the error is returned.
    const install_text = try withoutComments(arena, model.text.get(.runtime_install));
    const install_body = functionBody(install_text, "fn installLedgerModuleState(") orelse
        return gate.reject(.install_order, "{s} has no installLedgerModuleState body", .{paths.get(.runtime_install)});
    const refusal_at = std.mem.indexOf(u8, install_body, "invariant_adapter.requireLinked()") orelse
        return gate.reject(.install_order, "the ledger install path does not refuse an unexpected linked adapter", .{});
    const install_at = std.mem.indexOf(u8, install_body, "ledger.installStore(") orelse
        return gate.reject(.install_order, "the ledger install path no longer installs a store", .{});
    if (refusal_at > install_at) {
        return gate.reject(.install_order, "the ledger install path refuses an unexpected adapter only after installing the store", .{});
    }

    // --- the published catalog -----------------------------------------------
    const documented = (try docsRows(arena, model.text.get(.docs))) orelse
        return gate.reject(.docs_block_missing, "{s} has no machine-marked invariant catalog block", .{paths.get(.docs)});
    if (documented.len == 0) {
        return gate.reject(.docs_rows_empty, "documented invariant catalog is empty", .{});
    }
    if (documented.len != model.catalog.len) {
        return gate.reject(.docs_catalog_mismatch, "docs publish {d} catalog rows, kernel catalog has {d}", .{ documented.len, model.catalog.len });
    }
    for (model.catalog, 0..) |row, index| {
        var expected_buffer: [256]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buffer, "{d}|{s}|{s}|0x{x:0>8}|{s}", .{
            index,
            row.operation,
            row.sink,
            row.impl_id,
            effectFor(row.writes),
        });
        if (!std.mem.eql(u8, documented[index], expected)) {
            return gate.reject(.docs_catalog_mismatch, "docs row {d} is '{s}', kernel catalog says '{s}'", .{ index, documented[index], expected });
        }
    }
    if (std.mem.indexOf(u8, model.text.get(.docs), "certificate schema 4") == null or
        std.mem.indexOf(u8, model.text.get(.docs), "`zttp_pcc_v3`") == null)
    {
        return gate.reject(.docs_schema_statement, "verification docs do not state the current certificate schema and proof system", .{});
    }
    if (std.mem.indexOf(u8, model.text.get(.docs), "invariant wire schema 1") == null or
        std.mem.indexOf(u8, model.text.get(.docs), "invariant wire schema 2") == null)
    {
        return gate.reject(.docs_invariant_schema_statement, "{s} does not state both invariant wire schemas", .{paths.get(.docs)});
    }
    if (std.mem.indexOf(u8, model.text.get(.concepts), "### Application invariant") == null) {
        return gate.reject(.concepts_entry, "{s} has no Application invariant entry", .{paths.get(.concepts)});
    }

    // --- compiled behavioral evidence ----------------------------------------
    for (evidence) |item| {
        if (std.mem.indexOf(u8, model.text.get(item.input), item.marker) == null) {
            return gate.reject(.missing_evidence, "missing invariant evidence in {s}: {s}", .{ paths.get(item.input), item.marker });
        }
    }

    // --- the closed kind catalog, imported as a value ------------------------
    if (model.kinds.len == 0) {
        return gate.reject(.kind_table_floor, "kernel kind table is empty", .{});
    }
    var seen_ordinals: u32 = 0;
    for (model.kinds) |row| {
        if (row.description.len == 0) {
            return gate.reject(.kind_description_empty, "invariant kind '{s}' has no confirmed sentence", .{row.name});
        }
        if (row.predicate_version < 1) {
            return gate.reject(.kind_predicate_version, "invariant kind '{s}' has predicate version {d}", .{ row.name, row.predicate_version });
        }
        if (row.wire_ordinal >= 32) {
            return gate.reject(.kind_ordinal_range, "invariant kind '{s}' has wire ordinal {d}, at or above 32", .{ row.name, row.wire_ordinal });
        }
        const bit = @as(u32, 1) << @intCast(row.wire_ordinal);
        if (seen_ordinals & bit != 0) {
            return gate.reject(.kind_ordinal_duplicate, "invariant wire ordinal {d} is claimed twice", .{row.wire_ordinal});
        }
        seen_ordinals |= bit;
        const decoded = invariant.Kind.fromWire(row.wire_ordinal) orelse
            return gate.reject(.kind_ordinal_mismatch, "wire ordinal {d} decodes to no invariant kind", .{row.wire_ordinal});
        if (!std.mem.eql(u8, @tagName(decoded), row.name)) {
            return gate.reject(.kind_ordinal_mismatch, "wire ordinal {d} decodes to '{s}', the table row is '{s}'", .{ row.wire_ordinal, @tagName(decoded), row.name });
        }
    }

    // --- the two wire schemas, imported as values ----------------------------
    if (model.schema_version != 1) {
        return gate.reject(.schema_v1_moved, "the first invariant wire schema is {d}; deployed artifacts and existing ledger stores are bound to 1", .{model.schema_version});
    }
    if (model.schema_version_v2 == model.schema_version) {
        return gate.reject(.schema_versions_not_distinct, "both invariant wire schemas carry version {d}", .{model.schema_version});
    }
    if (!model.digest_domains.v1_preserved) {
        return gate.reject(.v1_digest_domain_changed, "schema 1 bytes no longer hash under '{s}'; every deployed artifact and ledger store is bound to those digests", .{v1_digest_domain_literal});
    }
    if (!model.digest_domains.v2_separated) {
        return gate.reject(.v2_digest_domain_shared, "schema 2 bytes hash under '{s}', so a schema 2 document can answer a schema 1 commitment", .{v1_digest_domain_literal});
    }

    // --- the confirmed-template boundary, measured rather than text-scanned --
    const expected_measurements = model.kinds.len * measured_schemas.len;
    if (model.config_acceptance.len != expected_measurements) {
        return gate.reject(.config_schema_coverage, "the confirmed-template boundary produced {d} measurements, expected {d}: one per catalog kind per wire schema", .{ model.config_acceptance.len, expected_measurements });
    }
    for (model.kinds) |row| {
        for (measured_schemas) |schema| {
            var measured = false;
            for (model.config_acceptance) |acceptance| {
                if (!std.mem.eql(u8, acceptance.name, row.name) or acceptance.schema != schema) continue;
                measured = true;
                if (mustAuthor(schema, row.required)) {
                    if (!acceptance.accepted) {
                        return gate.reject(.config_kind_missing, "{s} refuses catalog kind '{s}' under wire schema {d} with {s}", .{ paths.get(.config_tests), row.name, schema, acceptance.failure });
                    }
                    continue;
                }
                if (acceptance.accepted) {
                    return gate.reject(.config_schema_closure, "{s} authors kind '{s}' under wire schema {d}, whose decoder admits only the required kind", .{ paths.get(.config_tests), row.name, schema });
                }
                if (!std.mem.eql(u8, acceptance.failure, closed_schema_failure)) {
                    return gate.reject(.config_schema_closure, "{s} refuses kind '{s}' under wire schema {d} with {s}, expected {s}", .{ paths.get(.config_tests), row.name, schema, acceptance.failure, closed_schema_failure });
                }
            }
            if (!measured) {
                return gate.reject(.config_kind_missing, "catalog kind '{s}' was never offered to {s} under wire schema {d}", .{ row.name, paths.get(.config_tests), schema });
            }
        }
    }
    if (model.config_unknown_refusals.len != measured_schemas.len) {
        return gate.reject(.config_schema_coverage, "a kind the catalog does not name was offered under {d} wire schemas, expected {d}", .{ model.config_unknown_refusals.len, measured_schemas.len });
    }
    for (model.config_unknown_refusals) |refusal| {
        if (!refusal.refused) {
            return gate.reject(.config_accepts_unknown_kind, "{s} does not refuse a kind the catalog does not name under wire schema {d}", .{ paths.get(.config_tests), refusal.schema });
        }
    }

    // --- what `zttp invariant list` prints -----------------------------------
    if (countOccurrences(model.authoring, "predicate version ") != model.kinds.len) {
        return gate.reject(.authoring_output_mismatch, "authoring listing describes {d} kinds, the kind table has {d}", .{ countOccurrences(model.authoring, "predicate version "), model.kinds.len });
    }
    for (model.kinds) |row| {
        var block_buffer: [768]u8 = undefined;
        const block = try std.fmt.bufPrint(&block_buffer, "  {s}\n    {s}\n    predicate version {d}; {s}; {s}\n", .{
            row.name,
            row.description,
            row.predicate_version,
            if (row.required) "required before acceptance" else "optional for acceptance",
            if (row.applies_to_writes) "constrains operations that write" else "constrains operations that read",
        });
        if (std.mem.indexOf(u8, model.authoring, block) == null) {
            return gate.reject(.authoring_output_mismatch, "authoring listing does not state the kind table row for '{s}'", .{row.name});
        }
    }
    if (std.mem.indexOf(u8, model.text.get(.cli_src), "author.renderList(") == null) {
        return gate.reject(.cli_delegates_listing, "{s} no longer renders the catalog through the authoring module", .{paths.get(.cli_src)});
    }

    // --- the build wiring that makes this gate run at all --------------------
    const build_text = model.text.get(.build);
    if (std.mem.indexOf(u8, build_text, "b.step(\"test-invariant-drift\"") == null) {
        return gate.reject(.build_step_missing, "build.zig declares no test-invariant-drift step", .{});
    }
    const run_variable = blk: {
        const at = std.mem.indexOf(u8, build_text, "b.addRunArtifact(invariant_gate_exe)") orelse
            return gate.reject(.build_side_effects, "build.zig does not run the invariant gate binary", .{});
        const line_start = if (std.mem.lastIndexOfScalar(u8, build_text[0..at], '\n')) |nl| nl + 1 else 0;
        const line = std.mem.trim(u8, build_text[line_start..at], " \t");
        if (!std.mem.startsWith(u8, line, "const ")) {
            return gate.reject(.build_side_effects, "build.zig does not bind the invariant gate run step to a name", .{});
        }
        break :blk identifierAt(line, "const ".len);
    };
    var side_effect_buffer: [128]u8 = undefined;
    const side_effect_needle = try std.fmt.bufPrint(&side_effect_buffer, "{s}.has_side_effects = true;", .{run_variable});
    if (std.mem.indexOf(u8, build_text, side_effect_needle) == null) {
        return gate.reject(.build_side_effects, "build.zig does not force '{s}' to rerun; a Run step caches on its arguments, not on the files it reads", .{run_variable});
    }
    if (countOccurrences(build_text, "invariant_drift_step.dependOn(") < 5) {
        return gate.reject(.build_evidence_dependencies, "test-invariant-drift depends on {d} steps, expected the gate plus at least four compiled evidence roots", .{countOccurrences(build_text, "invariant_drift_step.dependOn(")});
    }
    if (std.mem.indexOf(u8, build_text, "scripts/check-invariants.sh") != null) {
        return gate.reject(.build_replaced_gate, "build.zig still runs the replaced invariant shell gate", .{});
    }
}

// ---------------------------------------------------------------------------
// Probes
// ---------------------------------------------------------------------------

const ProbeError = error{
    ProbeAnchorMissing,
    ProbeAnchorAmbiguous,
};

/// A mutation applied to the in-memory model, and the check that must reject
/// it. One per independent input, plus one per table floor.
const Probe = struct {
    name: []const u8,
    expect: Check,
    apply: *const fn (arena: std.mem.Allocator, model: *Model) anyerror!void,
};

fn replaceOnce(
    arena: std.mem.Allocator,
    model: *Model,
    input: Input,
    needle: []const u8,
    replacement: []const u8,
) !void {
    const text = model.text.get(input);
    switch (countOccurrences(text, needle)) {
        0 => return error.ProbeAnchorMissing,
        1 => {},
        else => return error.ProbeAnchorAmbiguous,
    }
    const at = std.mem.indexOf(u8, text, needle) orelse return error.ProbeAnchorMissing;
    const mutated = try arena.alloc(u8, text.len - needle.len + replacement.len);
    errdefer arena.free(mutated);
    @memcpy(mutated[0..at], text[0..at]);
    @memcpy(mutated[at..][0..replacement.len], replacement);
    @memcpy(mutated[at + replacement.len ..], text[at + needle.len ..]);
    model.text.set(input, mutated);
}

/// Rename every declaration the check accepts, not just the first. The check
/// is "at least one", so a probe that renames one of two leaves it satisfied
/// and reports itself as a probe failure. That is what would happen the day a
/// second expected-adapter declaration appears beside the first, and it would
/// read as a regression in whichever task added it.
fn probeKernel(arena: std.mem.Allocator, model: *Model) !void {
    const declarations = try adapterDeclarations(arena, model.text.get(.kernel));
    if (declarations.len == 0) return error.ProbeAnchorMissing;
    for (declarations, 0..) |name, index| {
        const needle = try std.fmt.allocPrint(arena, "pub const {s}", .{name});
        errdefer arena.free(needle);
        const replacement = try std.fmt.allocPrint(arena, "pub const probe_{d}_value", .{index});
        errdefer arena.free(replacement);
        try replaceOnce(arena, model, .kernel, needle, replacement);
    }
}

/// The kernel stops deriving its digest from a declared expected value. Task 3
/// wrote that check; it had no probe until the manifest gave it something to
/// mutate that is not also the declaration itself.
fn probeKernelDigestDerivation(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(
        arena,
        model,
        .kernel,
        "return adapterManifestDigest(expected_adapter_manifest);",
        "return adapterManifestDigest(a_value_this_file_does_not_declare);",
    );
}

/// The kernel's digest collapses to zero, which is what an encoder that hashed
/// nothing would return.
fn probeKernelDigestEmpty(_: std.mem.Allocator, model: *Model) !void {
    model.adapter_digest = [_]u8{0} ** 32;
}

fn probeProofSystem(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(arena, model, .proof_system, "ledger_call = 8", "ledger_call = 9");
}

fn probeCompiler(arena: std.mem.Allocator, model: *Model) !void {
    const resolver = functionBody(model.text.get(.compiler), "fn resolveLedger(") orelse return error.ProbeAnchorMissing;
    const rows = try compilerRows(arena, resolver);
    if (rows.len == 0) return error.ProbeAnchorMissing;
    const last = rows[rows.len - 1];
    const needle = try std.fmt.allocPrint(arena, "imported.name, \"{s}\")) return {d};", .{ last.name, last.index });
    errdefer arena.free(needle);
    const replacement = try std.fmt.allocPrint(arena, "imported.name, \"{s}\")) return 9;", .{last.name});
    errdefer arena.free(replacement);
    try replaceOnce(arena, model, .compiler, needle, replacement);
}

fn probeCompilerIr(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(arena, model, .compiler_ir, "ledger_call = 8", "ledger_call = 9");
}

fn probeNative(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(arena, model, .native, ".specifier = \"" ++ ledger_specifier ++ "\"", ".specifier = \"zttp:probe\"");
}

fn probeNativeBridge(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(arena, model, .native_bridge, "adaptModuleBinding(ledger.binding)", "probeBinding(ledger.binding)");
}

fn probeObserver(arena: std.mem.Allocator, model: *Model) !void {
    const rows = try observerRows(arena, model.text.get(.observer));
    if (rows.len == 0) return error.ProbeAnchorMissing;
    const last = rows[rows.len - 1];
    const needle = try std.fmt.allocPrint(arena, "\"{s}\"", .{last.atom});
    errdefer arena.free(needle);
    const replacement = try std.fmt.allocPrint(arena, "\"{s}_probe\"", .{last.atom});
    errdefer arena.free(replacement);
    try replaceOnce(arena, model, .observer, needle, replacement);
}

fn probeProducer(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(arena, model, .producer, ".ledger_call => .ledger_call", ".ledger_call => .capability_call");
}

fn probeArtifactGraph(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(arena, model, .artifact_graph, "collector.add(.invariant_ledger_adapter", "collector.add(.invariant_spec");
}

/// The graph reads the kernel's expectation again. This is the regression the
/// adapter manifest exists to prevent, so it is probed rather than assumed.
fn probeGraphFromKernel(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(
        arena,
        model,
        .artifact_graph,
        "inputs.invariant_adapter_digest orelse",
        "pcc.invariant.adapterDigest() orelse",
    );
}

fn probeProducerAdapter(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(
        arena,
        model,
        .producer,
        "artifact.invariant_adapter_digest = invariant_adapter.linkedDigest();",
        "artifact.invariant_adapter_digest = pcc.invariant.adapterDigest();",
    );
}

fn probeActivation(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(
        arena,
        model,
        .activation,
        ".invariant_adapter_digest = invariant_adapter.linkedDigest(),",
        ".invariant_adapter_digest = pcc.invariant.adapterDigest(),",
    );
}

fn probeAdapterBridge(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(
        arena,
        model,
        .adapter_bridge,
        ".identity = native.adapter_manifest.identity,",
        ".identity = pcc.invariant.expected_adapter_manifest.identity,",
    );
}

/// Move the refusal to after `installStore`, rather than delete it. Deleting
/// it would be caught by the presence clause, and a probe that trips the
/// presence clause says nothing about whether the order is checked.
/// The graph computes the member inline from the kernel's expected manifest.
/// It contains no `adapterDigest` token, so the single-spelling check ahead of
/// the scan does not see it.
fn probeGraphKernelValue(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(
        arena,
        model,
        .artifact_graph,
        "inputs.invariant_adapter_digest orelse",
        "pcc.invariant.adapterManifestDigest(pcc.invariant.expected_adapter_manifest) orelse",
    );
}

/// The bridge fills one manifest field from the kernel and leaves the rest
/// native. Every earlier clause still holds, and so does the floor test, since
/// the two strings are equal.
fn probeBridgeKernelIdentity(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(
        arena,
        model,
        .adapter_bridge,
        ".identity = native.adapter_manifest.identity,",
        ".identity = pcc.invariant.adapter_identity,",
    );
}

fn probeBridgeKernelSchema(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(
        arena,
        model,
        .adapter_bridge,
        ".store_schema_version = native.adapter_manifest.store_schema_version,",
        ".store_schema_version = pcc.invariant.adapter_store_schema_version,",
    );
}

/// The producer keeps binding from the bridge and reaches for the kernel's
/// catalog beside it. The binding checks pass; the scan does not.
fn probeProducerKernelValue(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(
        arena,
        model,
        .producer,
        "artifact.invariant_spec_digest = invariant_spec_digest;",
        "artifact.invariant_spec_digest = invariant_spec_digest;\n    _ = pcc.invariant.kind_table;",
    );
}

fn probeRuntimeInstall(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(
        arena,
        model,
        .runtime_install,
        "        try invariant_adapter.requireLinked();\n",
        "",
    );
    try replaceOnce(
        arena,
        model,
        .runtime_install,
        "            .invariant_digest = invariant.digest(bytes),\n        });\n",
        "            .invariant_digest = invariant.digest(bytes),\n        });\n        try invariant_adapter.requireLinked();\n",
    );
}

fn probeNativePostDispatch(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(
        arena,
        model,
        .native,
        "for (predicates) |row| try row.group_fn(group);",
        "try validateGroup(group);",
    );
}

fn probeNativeBaselineDispatch(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(
        arena,
        model,
        .native,
        "for (predicates) |row| try row.baseline_fn(self.allocator, handle, db, &self.config);",
        "try validatePostingsAndBalances(self.allocator, handle, db, &self.config);",
    );
}

fn probeNativeManifestDerivation(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(
        arena,
        model,
        .native,
        "for (binding.exports, 0..) |item, index| names[index] = item.name;",
        "names[0] = \"post\";",
    );
}

/// One row of the linked manifest moves to a predicate version the kernel does
/// not expect. Nothing in the text changes, so only the value comparison can
/// catch it.
fn probeManifestAgreement(arena: std.mem.Allocator, model: *Model) !void {
    if (model.native_manifest.predicates.len == 0) return error.ProbeAnchorMissing;
    const rows = try arena.dupe(ManifestRow, model.native_manifest.predicates);
    errdefer arena.free(rows);
    rows[0].predicate_version += 1;
    model.native_manifest.predicates = rows;
}

fn probeManifestEmpty(arena: std.mem.Allocator, model: *Model) !void {
    model.native_manifest.predicates = try arena.alloc(ManifestRow, 0);
}

fn renameEvidence(arena: std.mem.Allocator, model: *Model, input: Input) !void {
    for (evidence) |item| {
        if (item.input != input) continue;
        const replacement = try std.fmt.allocPrint(arena, "test \"probe renamed {s}", .{item.marker["test \"".len..]});
        errdefer arena.free(replacement);
        return replaceOnce(arena, model, input, item.marker, replacement);
    }
    return error.ProbeAnchorMissing;
}

fn probeCheckerTests(arena: std.mem.Allocator, model: *Model) !void {
    try renameEvidence(arena, model, .checker_tests);
}

fn probeAuthorSource(arena: std.mem.Allocator, model: *Model) !void {
    try renameEvidence(arena, model, .author_src);
}

fn probeConfigTests(arena: std.mem.Allocator, model: *Model) !void {
    try renameEvidence(arena, model, .config_tests);
}

fn probeConfigAcceptance(arena: std.mem.Allocator, model: *Model) !void {
    if (model.config_acceptance.len == 0) return error.ProbeAnchorMissing;
    const rows = try arena.dupe(ConfigAcceptance, model.config_acceptance);
    errdefer arena.free(rows);
    const last = &rows[rows.len - 1];
    last.accepted = false;
    last.failure = "a probe, not a measurement";
    model.config_acceptance = rows;
}

fn probeConfigUnknown(arena: std.mem.Allocator, model: *Model) !void {
    if (model.config_unknown_refusals.len == 0) return error.ProbeAnchorMissing;
    const rows = try arena.dupe(UnknownRefusal, model.config_unknown_refusals);
    errdefer arena.free(rows);
    rows[0].refused = false;
    model.config_unknown_refusals = rows;
}

fn probeConfigUnknownV2(arena: std.mem.Allocator, model: *Model) !void {
    if (model.config_unknown_refusals.len < 2) return error.ProbeAnchorMissing;
    const rows = try arena.dupe(UnknownRefusal, model.config_unknown_refusals);
    errdefer arena.free(rows);
    rows[rows.len - 1].refused = false;
    model.config_unknown_refusals = rows;
}

fn probeSchemaVersion(_: std.mem.Allocator, model: *Model) !void {
    model.schema_version = model.schema_version + 1;
}

fn probeSchemaVersionV2(_: std.mem.Allocator, model: *Model) !void {
    model.schema_version_v2 = model.schema_version;
}

/// A kind that is no longer required must stop being authorable under schema 1.
/// This is the one mutation that reaches the closed-schema branch while the
/// catalog holds a single required kind.
fn probeKindNotRequired(arena: std.mem.Allocator, model: *Model) !void {
    if (model.kinds.len == 0) return error.ProbeAnchorMissing;
    const rows = try arena.dupe(KindRow, model.kinds);
    errdefer arena.free(rows);
    rows[0].required = false;
    model.kinds = rows;
}

/// Drop one measurement. The floor ahead of the per-kind loop must see the
/// short table, rather than the loop reporting every kind it can still find.
fn probeConfigAcceptanceShort(_: std.mem.Allocator, model: *Model) !void {
    if (model.config_acceptance.len == 0) return error.ProbeAnchorMissing;
    model.config_acceptance = model.config_acceptance[0 .. model.config_acceptance.len - 1];
}

fn probeConfigUnknownShort(_: std.mem.Allocator, model: *Model) !void {
    if (model.config_unknown_refusals.len < 2) return error.ProbeAnchorMissing;
    model.config_unknown_refusals = model.config_unknown_refusals[0..1];
}

fn probeDigestDomainV1(_: std.mem.Allocator, model: *Model) !void {
    model.digest_domains.v1_preserved = false;
}

fn probeDigestDomainV2(_: std.mem.Allocator, model: *Model) !void {
    model.digest_domains.v2_separated = false;
}

fn probeDocsInvariantSchema(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(arena, model, .docs, "invariant wire schema 2", "invariant wire schema probe");
}

fn probeCliSource(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(arena, model, .cli_src, "author.renderList(", "author.renderProbe(");
}

fn probeDocs(arena: std.mem.Allocator, model: *Model) !void {
    if (model.catalog.len == 0) return error.ProbeAnchorMissing;
    const row = model.catalog[0];
    const needle = try std.fmt.allocPrint(arena, "- `0|{s}|{s}|0x{x:0>8}|{s}`", .{
        row.operation,
        row.sink,
        row.impl_id,
        effectFor(row.writes),
    });
    errdefer arena.free(needle);
    const replacement = try std.fmt.allocPrint(arena, "- `0|{s}|{s}|0x{x:0>8}|{s}`", .{
        row.operation,
        row.sink,
        row.impl_id,
        effectFor(!row.writes),
    });
    errdefer arena.free(replacement);
    try replaceOnce(arena, model, .docs, needle, replacement);
}

fn probeConcepts(arena: std.mem.Allocator, model: *Model) !void {
    try replaceOnce(arena, model, .concepts, "### Application invariant", "### Probe entry");
}

fn probeBuild(arena: std.mem.Allocator, model: *Model) !void {
    const text = model.text.get(.build);
    const at = std.mem.indexOf(u8, text, "b.addRunArtifact(invariant_gate_exe)") orelse return error.ProbeAnchorMissing;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
    const line = std.mem.trim(u8, text[line_start..at], " \t");
    if (!std.mem.startsWith(u8, line, "const ")) return error.ProbeAnchorMissing;
    const variable = identifierAt(line, "const ".len);
    const needle = try std.fmt.allocPrint(arena, "{s}.has_side_effects = true;", .{variable});
    errdefer arena.free(needle);
    const replacement = try std.fmt.allocPrint(arena, "{s}.has_side_effects = false;", .{variable});
    errdefer arena.free(replacement);
    try replaceOnce(arena, model, .build, needle, replacement);
}

fn probeCatalogRow(arena: std.mem.Allocator, model: *Model) !void {
    if (model.catalog.len == 0) return error.ProbeAnchorMissing;
    const rows = try arena.dupe(CatalogRow, model.catalog);
    errdefer arena.free(rows);
    const last = &rows[rows.len - 1];
    last.operation = try std.fmt.allocPrint(arena, "{s}_probe", .{last.operation});
    model.catalog = rows;
}

fn probeCatalogEmpty(arena: std.mem.Allocator, model: *Model) !void {
    model.catalog = try arena.alloc(CatalogRow, 0);
}

fn probeKindRow(arena: std.mem.Allocator, model: *Model) !void {
    if (model.kinds.len == 0) return error.ProbeAnchorMissing;
    const rows = try arena.dupe(KindRow, model.kinds);
    errdefer arena.free(rows);
    rows[0].description = "a probe sentence that the kind table does not state";
    model.kinds = rows;
}

fn probeKindsEmpty(arena: std.mem.Allocator, model: *Model) !void {
    model.kinds = try arena.alloc(KindRow, 0);
}

fn probeNativeExportDrop(arena: std.mem.Allocator, model: *Model) !void {
    if (model.native_exports.len == 0) return error.ProbeAnchorMissing;
    model.native_exports = try arena.dupe(NativeExport, model.native_exports[0 .. model.native_exports.len - 1]);
}

fn probeNativeExportsEmpty(arena: std.mem.Allocator, model: *Model) !void {
    model.native_exports = try arena.alloc(NativeExport, 0);
}

const probes = [_]Probe{
    .{ .name = "kernel", .expect = .kernel_adapter_declaration, .apply = probeKernel },
    .{ .name = "kernel-digest-derivation", .expect = .kernel_adapter_digest_derivation, .apply = probeKernelDigestDerivation },
    .{ .name = "kernel-digest-empty", .expect = .kernel_adapter_digest_empty, .apply = probeKernelDigestEmpty },
    .{ .name = "proof_system", .expect = .proof_system_tag, .apply = probeProofSystem },
    .{ .name = "compiler", .expect = .compiler_index_mismatch, .apply = probeCompiler },
    .{ .name = "compiler_ir", .expect = .compiler_ir_tag, .apply = probeCompilerIr },
    .{ .name = "native", .expect = .native_specifier, .apply = probeNative },
    .{ .name = "native_bridge", .expect = .bridge_not_adapted, .apply = probeNativeBridge },
    .{ .name = "observer", .expect = .observer_name_mismatch, .apply = probeObserver },
    .{ .name = "producer", .expect = .producer_tag_map, .apply = probeProducer },
    .{ .name = "artifact_graph", .expect = .graph_adapter_member, .apply = probeArtifactGraph },
    .{ .name = "activation", .expect = .activation_adapter_binding, .apply = probeActivation },
    .{ .name = "adapter_bridge", .expect = .bridge_reads_native, .apply = probeAdapterBridge },
    .{ .name = "runtime_install", .expect = .install_order, .apply = probeRuntimeInstall },
    .{ .name = "graph-kernel-value", .expect = .adapter_value_copied, .apply = probeGraphKernelValue },
    .{ .name = "bridge-kernel-identity", .expect = .adapter_value_copied, .apply = probeBridgeKernelIdentity },
    .{ .name = "bridge-kernel-schema", .expect = .adapter_value_copied, .apply = probeBridgeKernelSchema },
    .{ .name = "producer-kernel-value", .expect = .adapter_value_copied, .apply = probeProducerKernelValue },
    .{ .name = "graph-from-kernel", .expect = .graph_adapter_from_kernel, .apply = probeGraphFromKernel },
    .{ .name = "producer-adapter", .expect = .producer_adapter_binding, .apply = probeProducerAdapter },
    .{ .name = "native-post-dispatch", .expect = .native_post_dispatch, .apply = probeNativePostDispatch },
    .{ .name = "native-baseline-dispatch", .expect = .native_baseline_dispatch, .apply = probeNativeBaselineDispatch },
    .{ .name = "native-manifest-derivation", .expect = .native_manifest_derivation, .apply = probeNativeManifestDerivation },
    .{ .name = "manifest-agreement", .expect = .adapter_manifest_mismatch, .apply = probeManifestAgreement },
    .{ .name = "manifest-empty", .expect = .native_manifest_empty, .apply = probeManifestEmpty },
    .{ .name = "checker_tests", .expect = .missing_evidence, .apply = probeCheckerTests },
    .{ .name = "config_tests", .expect = .missing_evidence, .apply = probeConfigTests },
    .{ .name = "author_src", .expect = .missing_evidence, .apply = probeAuthorSource },
    .{ .name = "cli_src", .expect = .cli_delegates_listing, .apply = probeCliSource },
    .{ .name = "docs", .expect = .docs_catalog_mismatch, .apply = probeDocs },
    .{ .name = "concepts", .expect = .concepts_entry, .apply = probeConcepts },
    .{ .name = "build", .expect = .build_side_effects, .apply = probeBuild },
    .{ .name = "catalog", .expect = .compiler_index_mismatch, .apply = probeCatalogRow },
    .{ .name = "catalog-empty", .expect = .catalog_floor, .apply = probeCatalogEmpty },
    .{ .name = "kinds", .expect = .authoring_output_mismatch, .apply = probeKindRow },
    .{ .name = "kinds-empty", .expect = .kind_table_floor, .apply = probeKindsEmpty },
    .{ .name = "native-exports", .expect = .native_effect_mismatch, .apply = probeNativeExportDrop },
    .{ .name = "native-exports-empty", .expect = .native_exports_empty, .apply = probeNativeExportsEmpty },
    .{ .name = "config-acceptance", .expect = .config_kind_missing, .apply = probeConfigAcceptance },
    .{ .name = "config-unknown", .expect = .config_accepts_unknown_kind, .apply = probeConfigUnknown },
    .{ .name = "config-unknown-v2", .expect = .config_accepts_unknown_kind, .apply = probeConfigUnknownV2 },
    .{ .name = "config-acceptance-short", .expect = .config_schema_coverage, .apply = probeConfigAcceptanceShort },
    .{ .name = "config-unknown-short", .expect = .config_schema_coverage, .apply = probeConfigUnknownShort },
    .{ .name = "kind-not-required", .expect = .config_schema_closure, .apply = probeKindNotRequired },
    .{ .name = "schema-version", .expect = .schema_v1_moved, .apply = probeSchemaVersion },
    .{ .name = "schema-version-v2", .expect = .schema_versions_not_distinct, .apply = probeSchemaVersionV2 },
    .{ .name = "digest-domain-v1", .expect = .v1_digest_domain_changed, .apply = probeDigestDomainV1 },
    .{ .name = "digest-domain-v2", .expect = .v2_digest_domain_shared, .apply = probeDigestDomainV2 },
    .{ .name = "docs-invariant-schema", .expect = .docs_invariant_schema_statement, .apply = probeDocsInvariantSchema },
};

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

fn pathExists(arena: std.mem.Allocator, path: []const u8) bool {
    const path_z = arena.dupeZ(u8, path) catch return false;
    defer arena.free(path_z);
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0) catch return false;
    std.Io.Threaded.closeFd(fd);
    return true;
}

/// Walk up from the working directory rather than trusting it. The build runs
/// this from the build root, but a probe is run by hand from wherever the
/// developer is standing.
fn findRepoRoot(arena: std.mem.Allocator) ![]const u8 {
    var candidate: []const u8 = ".";
    var level: usize = 0;
    while (level < 8) : (level += 1) {
        const marker = try std.fs.path.join(arena, &.{ candidate, paths.get(.kernel) });
        const manifest = try std.fs.path.join(arena, &.{ candidate, "build.zig.zon" });
        if (pathExists(arena, marker) and pathExists(arena, manifest)) return candidate;
        candidate = try std.fs.path.join(arena, &.{ candidate, ".." });
    }
    return error.RepoRootNotFound;
}

fn loadModel(arena: std.mem.Allocator, root: []const u8, gate: *Gate) !Model {
    var text = std.EnumArray(Input, []const u8).initFill("");
    for (std.enums.values(Input)) |input| {
        const path = try std.fs.path.join(arena, &.{ root, paths.get(input) });
        if (!pathExists(arena, path)) {
            return gate.reject(.missing_source, "missing {s} source: {s}", .{ @tagName(input), paths.get(input) });
        }
        const contents = zts.file_io.readFile(arena, path, 16 * 1024 * 1024) catch {
            return gate.reject(.missing_source, "unreadable {s} source: {s}", .{ @tagName(input), paths.get(input) });
        };
        if (contents.len == 0) {
            return gate.reject(.empty_source, "empty {s} source: {s}", .{ @tagName(input), paths.get(input) });
        }
        text.set(input, contents);
    }

    var found = false;
    const native_exports = try buildNativeExports(arena, &found);
    const kinds = try buildKinds(arena);
    return .{
        .text = text,
        .catalog = try buildCatalog(arena),
        .kinds = kinds,
        .native_exports = native_exports,
        .native_binding_found = found,
        .authoring = try renderAuthoring(arena),
        .config_acceptance = try measureConfigAcceptance(arena, kinds),
        .config_unknown_refusals = try measureConfigRejectsUnknown(arena),
        .schema_version = invariant.schema_version,
        .schema_version_v2 = invariant.schema_version_v2,
        .digest_domains = try measureDigestDomains(arena, kinds),
        .adapter_digest = invariant.adapterDigest(),
        .native_manifest = try buildNativeManifest(arena),
        .expected_manifest = try buildExpectedManifest(arena),
    };
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

const usage =
    \\invariant-drift-gate - application-invariant drift and evidence gate
    \\
    \\  (no arguments)        validate every input, then run every mutation probe
    \\  --mutate <name>       validate with exactly one input mutated in memory
    \\  --list-probes         print the probe names
    \\
    \\Exit status
    \\  0  accepted
    \\  1  rejected; with --mutate this is the result a load-bearing input gives
    \\  2  with --mutate: the mutation slipped through, so that input is unchecked
    \\  3  the probe could not find its anchor, or the repository was not found
    \\
;

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const base = debug_allocator.allocator();

    var arena_state = std.heap.ArenaAllocator.init(base);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var io_backend = std.Io.Threaded.init(base, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buffer);

    var mutate: ?[]const u8 = null;
    var args_iterator = std.process.Args.Iterator.init(init.args);
    defer args_iterator.deinit();
    _ = args_iterator.next();
    while (args_iterator.next()) |raw| {
        if (std.mem.eql(u8, raw, "--help") or std.mem.eql(u8, raw, "-h")) {
            try stdout.interface.writeAll(usage);
            try stdout.interface.flush();
            return;
        }
        if (std.mem.eql(u8, raw, "--list-probes")) {
            for (probes) |probe| {
                try stdout.interface.print("{s}\t{s}\n", .{ probe.name, @tagName(probe.expect) });
            }
            try stdout.interface.flush();
            return;
        }
        if (std.mem.eql(u8, raw, "--mutate")) {
            const value = args_iterator.next() orelse {
                try stderr.interface.writeAll("application invariants: --mutate needs a probe name\n");
                try stderr.interface.flush();
                std.process.exit(3);
            };
            mutate = try arena.dupe(u8, value);
            continue;
        }
        try stderr.interface.print("application invariants: unknown argument '{s}'\n", .{raw});
        try stderr.interface.flush();
        std.process.exit(3);
    }

    const root = findRepoRoot(arena) catch {
        try stderr.interface.writeAll("application invariants: no repository root above the working directory\n");
        try stderr.interface.flush();
        std.process.exit(3);
    };

    var gate: Gate = .{};
    var model = loadModel(arena, root, &gate) catch |err| switch (err) {
        error.Rejected => {
            try stderr.interface.print("application invariants: {s}: {s}\n", .{ @tagName(gate.check), gate.message() });
            try stderr.interface.flush();
            std.process.exit(1);
        },
        else => return err,
    };

    if (mutate) |name| {
        const probe = for (probes) |candidate| {
            if (std.mem.eql(u8, candidate.name, name)) break candidate;
        } else {
            try stderr.interface.print("application invariants: no probe named '{s}'\n", .{name});
            try stderr.interface.flush();
            std.process.exit(3);
        };
        probe.apply(arena, &model) catch |err| {
            try stderr.interface.print("application invariants: probe '{s}' could not mutate its input: {s}\n", .{ probe.name, @errorName(err) });
            try stderr.interface.flush();
            std.process.exit(3);
        };
        validate(arena, &gate, model) catch |err| switch (err) {
            error.Rejected => {
                try stderr.interface.print(
                    "application invariants: probe '{s}' rejected by {s} (expected {s}): {s}\n",
                    .{ probe.name, @tagName(gate.check), @tagName(probe.expect), gate.message() },
                );
                try stderr.interface.flush();
                std.process.exit(1);
            },
            else => return err,
        };
        try stdout.interface.print(
            "application invariants: probe '{s}' was NOT rejected; input '{s}' is unchecked\n",
            .{ probe.name, probe.name },
        );
        try stdout.interface.flush();
        std.process.exit(2);
    }

    validate(arena, &gate, model) catch |err| switch (err) {
        error.Rejected => {
            try stderr.interface.print("application invariants: {s}: {s}\n", .{ @tagName(gate.check), gate.message() });
            try stderr.interface.flush();
            std.process.exit(1);
        },
        else => return err,
    };

    for (probes) |probe| {
        var mutated = model;
        var probe_gate: Gate = .{};
        probe.apply(arena, &mutated) catch |err| {
            try stderr.interface.print(
                "application invariants: probe '{s}' could not mutate its input: {s}\n",
                .{ probe.name, @errorName(err) },
            );
            try stderr.interface.flush();
            std.process.exit(1);
        };
        validate(arena, &probe_gate, mutated) catch |err| switch (err) {
            error.Rejected => {
                if (probe_gate.check != probe.expect) {
                    try stderr.interface.print(
                        "application invariants: probe '{s}' was rejected by {s}, expected {s}: {s}\n",
                        .{ probe.name, @tagName(probe_gate.check), @tagName(probe.expect), probe_gate.message() },
                    );
                    try stderr.interface.flush();
                    std.process.exit(1);
                }
                continue;
            },
            else => return err,
        };
        try stderr.interface.print(
            "application invariants: probe '{s}' passed validation; {s} checks nothing\n",
            .{ probe.name, @tagName(probe.expect) },
        );
        try stderr.interface.flush();
        std.process.exit(1);
    }

    try stdout.interface.print(
        "application invariants: {d} sources, {d} catalog rows, {d} kinds over {d} wire schemas, " ++
            "{d} native exports, {d} linked adapter predicates and {d} compiled evidence markers agree; " ++
            "{d} mutation probes reject\n",
        .{
            std.enums.values(Input).len,
            model.catalog.len,
            model.kinds.len,
            measured_schemas.len,
            model.native_exports.len,
            model.native_manifest.predicates.len,
            evidence.len,
            probes.len,
        },
    );
    try stdout.interface.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "every independent input carries a mutation probe" {
    // A gate grows an input the day somebody adds a row to `paths`. Without
    // this, the new input is read, never compared, and counted in the summary.
    for (std.enums.values(Input)) |input| {
        var covered = false;
        for (probes) |probe| {
            if (std.mem.eql(u8, probe.name, @tagName(input))) covered = true;
        }
        try testing.expect(covered);
    }
    try testing.expect(probes.len >= std.enums.values(Input).len);
}

test "every adapter and manifest check is exercised by a probe" {
    // The coverage test above counts inputs, not checks, so a check added
    // without a probe would be invisible to it. This family is the one this
    // gate exists for, and it self-extends: a new check whose name mentions
    // the adapter, its manifest, or its dispatch must be probed.
    var covered: usize = 0;
    inline for (@typeInfo(Check).@"enum".fields) |field| {
        const names_family =
            std.mem.indexOf(u8, field.name, "adapter") != null or
            std.mem.indexOf(u8, field.name, "manifest") != null or
            std.mem.indexOf(u8, field.name, "dispatch") != null or
            std.mem.indexOf(u8, field.name, "bridge") != null;
        if (names_family) {
            const check: Check = @enumFromInt(field.value);
            var probed = false;
            for (probes) |probe| {
                if (probe.expect == check) probed = true;
            }
            testing.expect(probed) catch |err| {
                std.debug.print("check '{s}' has no mutation probe\n", .{field.name});
                return err;
            };
            covered += 1;
        }
    }
    // A filter that matched nothing would pass the loop above in silence.
    // Fifteen is the family's size today; shrinking it is a deliberate edit.
    try testing.expect(covered >= 15);
}

test "no probe expects the absence of a rejection" {
    for (probes) |probe| {
        try testing.expect(probe.expect != .none);
    }
}

test "occurrence counting does not overlap a repeated needle" {
    try testing.expectEqual(@as(usize, 2), countOccurrences("abab", "ab"));
    try testing.expectEqual(@as(usize, 1), countOccurrences("aaa", "aa"));
    try testing.expectEqual(@as(usize, 0), countOccurrences("abc", "z"));
}

test "the forbidden kernel read set is non-empty and spares the shared type and encoder" {
    // A scan whose set is empty finds nothing in any text and reports a pass
    // over every producer surface. The set is derived from the kernel's
    // namespace, so this is the floor that makes the derivation mean something.
    try testing.expect(forbidden_kernel_reads.len >= 5);
    var saw_identity = false;
    var saw_expected_manifest = false;
    for (forbidden_kernel_reads) |name| {
        if (std.mem.eql(u8, name, "adapter_identity")) saw_identity = true;
        if (std.mem.eql(u8, name, "expected_adapter_manifest")) saw_expected_manifest = true;
    }
    try testing.expect(saw_identity);
    try testing.expect(saw_expected_manifest);

    // Values are forbidden; the type and the encoder both sides must name are
    // not, and neither is the specification surface, which is a function of
    // artifact bytes rather than a constant.
    try testing.expect(copiedKernelValue("pcc.invariant.adapter_identity") != null);
    try testing.expect(copiedKernelValue("pcc.invariant.expected_adapter_manifest") != null);
    try testing.expect(copiedKernelValue("pcc.invariant.kind_table") != null);
    try testing.expect(copiedKernelValue("pcc.invariant.adapterManifestDigest(m)") == null);
    try testing.expect(copiedKernelValue("pcc.invariant.AdapterManifest") == null);
    try testing.expect(copiedKernelValue("pcc.invariant.AdapterPredicate") == null);
    try testing.expect(copiedKernelValue("pcc.invariant.digest(bytes)") == null);
    try testing.expect(copiedKernelValue("pcc.invariant.decode(bytes)") == null);
}

test "comment stripping blanks a line comment and keeps the length" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = "const a = one(); // never call two()\nconst b = two();\n";
    const stripped = try withoutComments(arena, source);
    try testing.expectEqual(source.len, stripped.len);
    try testing.expectEqual(@as(usize, 1), countOccurrences(stripped, "two()"));
    try testing.expectEqual(@as(usize, 2), countOccurrences(source, "two()"));
    try testing.expect(std.mem.indexOf(u8, stripped, "const b = two();") != null);
}

test "a function body is delimited by brace depth" {
    const source =
        \\fn outer() void {
        \\    const value = .{ .a = 1 };
        \\    _ = value;
        \\}
        \\
    ;
    const body = functionBody(source, "fn outer(") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, body, ".a = 1") != null);
    try testing.expect(std.mem.indexOf(u8, body, "fn outer") == null);
}

test "call arguments split at top level and not inside a nested call" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source = "try collector.add(.invariant_ledger_adapter, 0, pcc.invariant.adapterDigest());";
    const open = std.mem.indexOfScalar(u8, source, '(') orelse return error.TestUnexpectedResult;
    const args = (try splitArguments(arena_state.allocator(), source, open)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), args.len);
    try testing.expectEqualStrings(".invariant_ledger_adapter", args[0]);
    try testing.expectEqualStrings("pcc.invariant.adapterDigest()", args[2]);
}

test "compiler resolver rows read a name and its catalog index" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const body =
        \\    if (!std.mem.eql(u8, imported.module, "zttp:ledger")) return null;
        \\    if (std.mem.eql(u8, imported.name, "post")) return 0;
        \\    if (std.mem.eql(u8, imported.name, "balance")) return 1;
        \\
    ;
    const rows = try compilerRows(arena_state.allocator(), body);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("post", rows[0].name);
    try testing.expectEqual(@as(u32, 1), rows[1].index);
}

test "observer rows read the encoded atom and the operation it decodes to" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source =
        \\    if (std.mem.eql(u8, value, "zttp:ledger#post")) return .post;
        \\    if (std.mem.eql(u8, value, "zttp:ledger#balance")) return .balance;
        \\
    ;
    const rows = try observerRows(arena_state.allocator(), source);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("zttp:ledger#balance", rows[1].atom);
    try testing.expectEqualStrings("balance", rows[1].operation);
}

test "documented rows are read only from inside the machine-marked block" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source =
        \\- `not in the block`
        \\<!-- application-invariants: catalog -->
        \\- `0|post|ledger_post|0x4c500001|write`
        \\<!-- application-invariants: evidence -->
        \\- `also not in the block`
        \\
    ;
    const rows = (try docsRows(arena_state.allocator(), source)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("0|post|ledger_post|0x4c500001|write", rows[0]);
    try testing.expect((try docsRows(arena_state.allocator(), "no markers here")) == null);
}

test "a second ledger_call tag is ambiguous rather than a pass on the first" {
    // The predecessor matched every `ledger_call = N`, required exactly one,
    // and only then compared N to 8. Counting the literal `ledger_call = 8`
    // instead would call a file holding both an 8 and a 9 clean.
    try testing.expectEqual(@as(?u32, 8), ledgerCallTag("    ledger_call = 8,\n"));
    try testing.expectEqual(@as(?u32, 9), ledgerCallTag("    ledger_call = 9,\n"));
    try testing.expectEqual(@as(?u32, null), ledgerCallTag("    ledger_call = 8,\n    ledger_call = 9,\n"));
    try testing.expectEqual(@as(?u32, null), ledgerCallTag("    capability_call = 7,\n"));
    try testing.expectEqual(@as(?u32, null), ledgerCallTag("    ledger_call = ,\n"));
    // A switch prong is not an assignment: `=>` contains `=`, and the real
    // proof IR holds two prongs beside its one tag.
    try testing.expectEqual(
        @as(?u32, 8),
        ledgerCallTag("    ledger_call = 8,\n    .plain, .ledger_call => false,\n    .plain, .ledger_call => null,\n"),
    );
}

test "the confirmed template authors every catalog kind under the schema that can carry it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const kinds = try buildKinds(arena);
    const rows = try measureConfigAcceptance(arena, kinds);
    try testing.expect(kinds.len > 0);
    try testing.expectEqual(kinds.len * measured_schemas.len, rows.len);
    for (kinds) |kind| {
        for (measured_schemas) |schema| {
            var seen = false;
            for (rows) |row| {
                if (!std.mem.eql(u8, row.name, kind.name) or row.schema != schema) continue;
                seen = true;
                // The expected verdict per schema, not "accepted everywhere":
                // schema 1 carries one kind in its header and admits only the
                // required one, so a kind it must not carry has to be refused
                // by name rather than by any error that happens to arrive.
                try testing.expectEqual(mustAuthor(schema, kind.required), row.accepted);
                if (!row.accepted) try testing.expectEqualStrings(closed_schema_failure, row.failure);
            }
            try testing.expect(seen);
        }
    }
    // Schema 1 is the closed one, schema 2 the open one. With one required
    // kind both rules agree on every row, so state the rule itself as well.
    try testing.expect(mustAuthor(invariant.schema_version, true));
    try testing.expect(!mustAuthor(invariant.schema_version, false));
    try testing.expect(mustAuthor(invariant.schema_version_v2, true));
    try testing.expect(mustAuthor(invariant.schema_version_v2, false));

    const refusals = try measureConfigRejectsUnknown(arena);
    try testing.expectEqual(measured_schemas.len, refusals.len);
    for (refusals, measured_schemas) |refusal, schema| {
        try testing.expectEqual(schema, refusal.schema);
        try testing.expect(refusal.refused);
    }
}

test "the two wire schemas hash under different digest domains" {
    // The gate states the schema 1 domain itself rather than reading the
    // kernel's constant, so this measurement disagrees when either side moves.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const kinds = try buildKinds(arena);
    try testing.expect(kinds.len > 0);
    const measured = try measureDigestDomains(arena, kinds);
    try testing.expect(measured.v1_preserved);
    try testing.expect(measured.v2_separated);

    // With no kinds there is nothing to author, so nothing is measured, and
    // the gate must not read that as a pass.
    const none = try measureDigestDomains(arena, &.{});
    try testing.expect(!none.v1_preserved);
    try testing.expect(!none.v2_separated);
}

test "the schema 2 template names the required kinds beside the one under test" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const document = try confirmedTemplateV2(arena, unknown_kind_name);
    try testing.expect(std.mem.indexOf(u8, document, unknown_kind_name) != null);
    for (std.enums.values(invariant.Kind)) |kind| {
        if (!invariant.kindInfo(kind).required) continue;
        try testing.expect(std.mem.indexOf(u8, document, @tagName(kind)) != null);
    }
    // The document must still parse as JSON of the shape the boundary expects,
    // which its refusal proves: an unparsable document fails before the kind.
    try testing.expectError(error.UnsupportedInvariantKind, invariant_config.parse(arena, document));
}

test "the expected adapter declaration is found by meaning, not by its name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const identity = "pub const adapter_identity = \"x\";\npub const unrelated = 1;\n";
    const renamed = "pub const expected_manifest = .{};\npub const unrelated = 1;\n";
    const first = try adapterDeclarations(arena, identity);
    try testing.expectEqual(@as(usize, 1), first.len);
    try testing.expectEqualStrings("adapter_identity", first[0]);
    const second = try adapterDeclarations(arena, renamed);
    try testing.expectEqual(@as(usize, 1), second.len);
    try testing.expectEqualStrings("expected_manifest", second[0]);
    try testing.expectEqual(@as(usize, 0), (try adapterDeclarations(arena, "pub const other = 1;\n")).len);
    // Two of them is the shape task 5 may bring. The check accepts it, so the
    // probe must rename both rather than assume there is one.
    const both = try adapterDeclarations(arena, identity ++ renamed);
    try testing.expectEqual(@as(usize, 2), both.len);
}

test "the authoring listing states every row of the kernel kind table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rendered = try renderAuthoring(arena);
    const rows = try buildKinds(arena);
    try testing.expect(rows.len > 0);
    try testing.expectEqual(rows.len, countOccurrences(rendered, "predicate version "));
    for (rows) |row| {
        try testing.expect(std.mem.indexOf(u8, rendered, row.name) != null);
        try testing.expect(std.mem.indexOf(u8, rendered, row.description) != null);
    }
}

//! Building the canonical executable graph for a deployment artifact.
//!
//! The producer runs this over the sections it is about to embed; the consumer
//! runs the same code over the sections it just loaded. Neither side reads the
//! other's inventory: the whole point of the comparison in the acceptance
//! kernel is that the two lists were derived independently from the same bytes.
//!
//! Every digest here is over the exact bytes that end up in the artifact. The
//! nested-function and constant-pool members are byte ranges inside the module
//! blob, found by `bytecode_cache.walkExecutableSpans`, so no member is a hash
//! of a re-encoding of something.

const std = @import("std");
const zts = @import("zts");
const pcc = @import("zttp_proof_checker");

const graph = pcc.executable_graph;

pub const Member = graph.Member;
pub const MemberKind = graph.MemberKind;

/// Members one artifact may commit. Above this the artifact is refused rather
/// than committed in part.
pub const max_members: usize = 4096;
/// Functions one module blob may carry.
pub const max_functions_per_module: usize = 1024;

pub const Error = error{
    TooManyMembers,
    TooManyFunctions,
    MalformedBytecodeStream,
    OutOfMemory,
};

pub const Inputs = struct {
    /// Section 1, exactly as embedded.
    bytecode: []const u8,
    /// Section 2 entries, in load order.
    dep_bytecodes: []const []const u8 = &.{},
    /// SHA-256 of section 3, exactly as embedded. Absent only for an artifact
    /// built with no contract, which the strict path refuses separately.
    contract_digest: ?[32]u8 = null,
    /// SHA-256 of section 4, exactly as embedded. A digest rather than the
    /// bytes because the consumer keeps the hash of what it read, and both
    /// sides must fold the same value.
    policy_section_digest: [32]u8,
    /// Module specifiers in the contract's declared order. Order is part of the
    /// commitment: the same set imported in a different order is a different
    /// program.
    module_specifiers: []const []const u8 = &.{},
    /// The core source profile identifier.
    core_profile_id: []const u8,
    core_grammar_hash: [32]u8,
    semantics_hash: [32]u8,
    capability_hash: [32]u8,
    frontend_profile_id: ?[]const u8 = null,
    frontend_grammar_hash: ?[32]u8 = null,
    /// Digest of the canonical proof IR the certificate carries. Absent for an
    /// artifact built without one; the acceptance kernel refuses such an
    /// artifact for production, and says which member was missing.
    proof_ir_digest: ?[32]u8 = null,
    /// Cycle-safe digest of every certificate byte. Absent with no certificate.
    proof_certificate_digest: ?[32]u8 = null,
};

/// The identity half of the commitment: which modules the handler imports, and
/// which compiler surface produced it. Producer and consumer reach these from
/// different types - the build holds a `HandlerContract`, the server holds the
/// runtime projection of one - so the graph takes the values rather than either
/// type.
pub const Identity = struct {
    module_specifiers: []const []const u8 = &.{},
    core_profile_id: []const u8 = "",
    core_grammar_hash: [32]u8 = [_]u8{0} ** 32,
    semantics_hash: [32]u8 = [_]u8{0} ** 32,
    capability_hash: [32]u8 = [_]u8{0} ** 32,
    frontend_profile_id: ?[]const u8 = null,
    frontend_grammar_hash: ?[32]u8 = null,
};

/// Read the identity out of a compile-time handler contract.
pub fn identityFromContract(contract: *const zts.HandlerContract) Identity {
    var identity = Identity{
        .module_specifiers = contract.modules.items,
        .core_profile_id = contract.source_identity.core_profile.id(),
        .core_grammar_hash = contract.source_identity.core_grammar_hash,
        .semantics_hash = contract.source_identity.semantics_hash,
    };
    if (contract.capabilities) |caps| identity.capability_hash = caps.hash;
    if (contract.source_identity.frontend) |frontend| {
        identity.frontend_profile_id = frontend.profile.id();
        identity.frontend_grammar_hash = frontend.grammar_hash;
    }
    return identity;
}

/// The pieces of a deployment artifact as the producer and the consumer both
/// see them.
pub const ArtifactInputs = struct {
    bytecode: []const u8,
    dep_bytecodes: []const []const u8 = &.{},
    /// Section 3 bytes when the caller holds them.
    contract_section: ?[]const u8 = null,
    /// SHA-256 of section 4. The producer hashes the bytes it is about to embed
    /// once and passes the same digest here and into the signed claim.
    policy_section_digest: [32]u8,
    /// Absent for an artifact built with no contract. That yields a real,
    /// weaker commitment - no module identities, no source identity - rather
    /// than a pretend-complete one, and the strict activation path refuses such
    /// an artifact by naming the member kinds it is missing.
    identity: Identity = .{},
    proof_ir_digest: ?[32]u8 = null,
    proof_certificate_digest: ?[32]u8 = null,
};

/// Project the artifact onto the graph inputs.
pub fn fromArtifact(inputs: ArtifactInputs) Inputs {
    return .{
        .bytecode = inputs.bytecode,
        .dep_bytecodes = inputs.dep_bytecodes,
        .contract_digest = if (inputs.contract_section) |bytes| digestOf(bytes) else null,
        .policy_section_digest = inputs.policy_section_digest,
        .module_specifiers = inputs.identity.module_specifiers,
        .core_profile_id = inputs.identity.core_profile_id,
        .core_grammar_hash = inputs.identity.core_grammar_hash,
        .semantics_hash = inputs.identity.semantics_hash,
        .capability_hash = inputs.identity.capability_hash,
        .frontend_profile_id = inputs.identity.frontend_profile_id,
        .frontend_grammar_hash = inputs.identity.frontend_grammar_hash,
        .proof_ir_digest = inputs.proof_ir_digest,
        .proof_certificate_digest = inputs.proof_certificate_digest,
    };
}

const Collector = struct {
    out: []Member,
    count: usize = 0,

    fn add(self: *Collector, kind: MemberKind, ordinal: u32, digest: [32]u8) Error!void {
        if (self.count >= self.out.len) return error.TooManyMembers;
        self.out[self.count] = .{ .kind = kind, .ordinal = ordinal, .digest = digest };
        self.count += 1;
    }
};

pub fn digestOf(bytes: []const u8) [32]u8 {
    return graph.digestBytes(bytes);
}

fn addModuleSpans(
    collector: *Collector,
    blob: []const u8,
    spans: []zts.bytecode_cache.ExecutableSpan,
    next_ordinal: *u32,
) Error!void {
    const count = zts.bytecode_cache.walkExecutableSpans(blob, spans) catch |err| return switch (err) {
        error.TooManyFunctions => error.TooManyFunctions,
        error.MalformedBytecodeStream => error.MalformedBytecodeStream,
    };
    for (spans[0..count]) |span| {
        const ordinal = next_ordinal.*;
        next_ordinal.* += 1;
        try collector.add(
            .nested_function,
            ordinal,
            digestOf(blob[span.code_start..][0..span.code_len]),
        );
        try collector.add(
            .constant_pool,
            ordinal,
            digestOf(blob[span.constants_start..][0..span.constants_len]),
        );
    }
}

/// Build the canonical member inventory for one artifact.
///
/// `out` receives the members in canonical order. The returned slice is what
/// `pcc.executable_graph.computeRoot` folds; a caller must not reorder it.
pub fn build(
    allocator: std.mem.Allocator,
    inputs: Inputs,
    out: []Member,
) Error![]Member {
    var collector = Collector{ .out = out };

    try collector.add(.main_bytecode, 0, digestOf(inputs.bytecode));
    for (inputs.dep_bytecodes, 0..) |dep, index| {
        try collector.add(.dep_bytecode, @intCast(index), digestOf(dep));
    }

    const spans = try allocator.alloc(zts.bytecode_cache.ExecutableSpan, max_functions_per_module);
    defer allocator.free(spans);
    var function_ordinal: u32 = 0;
    try addModuleSpans(&collector, inputs.bytecode, spans, &function_ordinal);
    for (inputs.dep_bytecodes) |dep| {
        try addModuleSpans(&collector, dep, spans, &function_ordinal);
    }

    for (inputs.module_specifiers, 0..) |specifier, index| {
        try collector.add(.module_identity, @intCast(index), digestOf(specifier));
    }

    var native_ordinal: u32 = 0;
    for (inputs.module_specifiers) |specifier| {
        for (zts.builtinModules) |binding| {
            if (!std.mem.eql(u8, binding.specifier, specifier)) continue;
            try collector.add(.native_module_identity, native_ordinal, zts.ModuleMetadata.nativeBindingDigest(binding));
            native_ordinal += 1;
            break;
        }
    }

    if (inputs.contract_digest) |digest| {
        try collector.add(.contract_bytes, 0, digest);
    }
    try collector.add(.runtime_policy_bytes, 0, inputs.policy_section_digest);

    try collector.add(.source_profile_core, 0, digestOf(inputs.core_profile_id));
    if (inputs.frontend_profile_id) |id| {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(id);
        hasher.update("\x00");
        hasher.update(&(inputs.frontend_grammar_hash orelse [_]u8{0} ** 32));
        try collector.add(.source_profile_frontend, 0, hasher.finalResult());
    }
    try collector.add(.core_grammar, 0, inputs.core_grammar_hash);
    try collector.add(.semantics, 0, inputs.semantics_hash);
    try collector.add(.capability_matrix, 0, inputs.capability_hash);
    if (inputs.proof_ir_digest) |digest| {
        try collector.add(.proof_ir, 0, digest);
    }
    if (inputs.proof_certificate_digest) |digest| {
        try collector.add(.proof_certificate, 0, digest);
    }

    const members = out[0..collector.count];
    std.mem.sort(Member, members, {}, struct {
        fn lt(_: void, a: Member, b: Member) bool {
            return Member.order(a, b) == .lt;
        }
    }.lt);
    return members;
}

/// Build the inventory and fold it into one root in a single call.
pub fn buildRoot(
    allocator: std.mem.Allocator,
    inputs: Inputs,
    out: []Member,
) !struct { members: []Member, root: [32]u8 } {
    const members = try build(allocator, inputs, out);
    return .{ .members = members, .root = try graph.computeRoot(members) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Fixtures shared by every test that has to produce a real artifact.
pub const test_support = struct {
    /// A serialized module blob with one nested function, built the same way
    /// the compiler builds one. Any test that exercises the artifact tail needs
    /// a blob the span walker can actually read, so this lives here rather than
    /// being retyped in each caller.
    pub fn moduleBlob(allocator: std.mem.Allocator, code_seed: u8, out: []u8) ![]const u8 {
        var atoms = zts.AtomTable.init(allocator);
        defer atoms.deinit();

        const nested_code = try allocator.dupe(u8, &[_]u8{ code_seed, @intFromEnum(zts.bytecode.Opcode.ret) });
        const nested_constants = try allocator.alloc(zts.JSValue, 0);
        const nested_upvalues = try allocator.alloc(zts.bytecode.UpvalueInfo, 0);
        const nested = try allocator.create(zts.bytecode.FunctionBytecode);
        nested.* = .{
            .header = .{},
            .name_atom = 0,
            .arg_count = 0,
            .local_count = 0,
            .stack_size = 1,
            .flags = .{},
            .upvalue_count = 0,
            .upvalue_info = nested_upvalues,
            .code = nested_code,
            .constants = nested_constants,
            .source_map = null,
            .line_table = null,
        };
        defer {
            allocator.free(nested.code);
            allocator.free(nested.constants);
            allocator.free(nested.upvalue_info);
            allocator.destroy(nested);
        }

        const top_code = try allocator.dupe(u8, &[_]u8{
            @intFromEnum(zts.bytecode.Opcode.push_const),
            0,
            0,
            @intFromEnum(zts.bytecode.Opcode.ret),
        });
        const top_constants = try allocator.alloc(zts.JSValue, 1);
        top_constants[0] = zts.JSValue.fromExternPtr(nested);
        const top_upvalues = try allocator.alloc(zts.bytecode.UpvalueInfo, 0);
        const top = try allocator.create(zts.bytecode.FunctionBytecode);
        top.* = .{
            .header = .{},
            .name_atom = 0,
            .arg_count = 0,
            .local_count = 0,
            .stack_size = 2,
            .flags = .{},
            .upvalue_count = 0,
            .upvalue_info = top_upvalues,
            .code = top_code,
            .constants = top_constants,
            .source_map = null,
            .line_table = null,
        };
        defer {
            allocator.free(top.code);
            allocator.free(top.constants);
            allocator.free(top.upvalue_info);
            allocator.destroy(top);
        }

        var writer = zts.bytecode_cache.SliceWriter{ .buffer = out };
        try zts.bytecode_cache.serializeBytecodeWithAtomsAndShapes(top, &atoms, &.{}, &writer, allocator);
        return writer.getWritten();
    }
};

fn sampleInputs(main: []const u8, deps: []const []const u8) Inputs {
    return .{
        .bytecode = main,
        .dep_bytecodes = deps,
        .contract_digest = graph.digestBytes("{\"version\":18}"),
        .policy_section_digest = graph.digestBytes("policy-bytes"),
        .module_specifiers = &.{ "zttp:json", "./helper.ts" },
        .core_profile_id = "zts-model-1",
        .core_grammar_hash = [_]u8{0xA1} ** 32,
        .semantics_hash = [_]u8{0xB2} ** 32,
        .capability_hash = [_]u8{0xC3} ** 32,
        .proof_ir_digest = [_]u8{0xD4} ** 32,
        .proof_certificate_digest = [_]u8{0xE5} ** 32,
    };
}

test "the inventory covers every executable and authority-bearing member" {
    const allocator = testing.allocator;
    var main_buf: [4096]u8 = undefined;
    var dep_buf: [4096]u8 = undefined;
    const main = try test_support.moduleBlob(allocator, 0x10, &main_buf);
    const dep = try test_support.moduleBlob(allocator, 0x20, &dep_buf);
    const deps = [_][]const u8{dep};

    const out = try allocator.alloc(Member, max_members);
    defer allocator.free(out);
    const members = try build(allocator, sampleInputs(main, &deps), out);

    var seen = std.EnumSet(MemberKind).initEmpty();
    for (members) |member| seen.insert(member.kind);

    // Every kind a production artifact must commit, plus the ones this fixture
    // exercises. The frontend profile is genuinely absent here.
    inline for (@typeInfo(MemberKind).@"enum".fields) |field| {
        const kind: MemberKind = @enumFromInt(field.value);
        if (kind == .source_profile_frontend) continue;
        try testing.expect(seen.contains(kind));
    }

    // Two modules, two functions each: four nested-function members and four
    // constant-pool members, numbered across modules in load order.
    var nested: usize = 0;
    var pools: usize = 0;
    for (members) |member| {
        if (member.kind == .nested_function) nested += 1;
        if (member.kind == .constant_pool) pools += 1;
    }
    try testing.expectEqual(@as(usize, 4), nested);
    try testing.expectEqual(@as(usize, 4), pools);

    _ = try graph.computeRoot(members);
}

test "the same inputs produce the same inventory and root" {
    const allocator = testing.allocator;
    var main_buf: [4096]u8 = undefined;
    var dep_buf: [4096]u8 = undefined;
    const main = try test_support.moduleBlob(allocator, 0x10, &main_buf);
    const dep = try test_support.moduleBlob(allocator, 0x20, &dep_buf);
    const deps = [_][]const u8{dep};

    const out_a = try allocator.alloc(Member, max_members);
    defer allocator.free(out_a);
    const out_b = try allocator.alloc(Member, max_members);
    defer allocator.free(out_b);
    const first = try buildRoot(allocator, sampleInputs(main, &deps), out_a);
    const second = try buildRoot(allocator, sampleInputs(main, &deps), out_b);

    try testing.expectEqual(first.members.len, second.members.len);
    try testing.expectEqualSlices(u8, &first.root, &second.root);
}

test "mutating any member class moves the root" {
    const allocator = testing.allocator;
    var main_buf: [4096]u8 = undefined;
    var dep_buf: [4096]u8 = undefined;
    const main = try test_support.moduleBlob(allocator, 0x10, &main_buf);
    const dep = try test_support.moduleBlob(allocator, 0x20, &dep_buf);
    const deps = [_][]const u8{dep};

    const out = try allocator.alloc(Member, max_members);
    defer allocator.free(out);
    const base = (try buildRoot(allocator, sampleInputs(main, &deps), out)).root;

    const Mutation = struct {
        name: []const u8,
        apply: *const fn (*Inputs) void,
    };
    const mutations = [_]Mutation{
        .{ .name = "contract", .apply = struct {
            fn f(i: *Inputs) void {
                i.contract_digest = graph.digestBytes("{\"version\":19}");
            }
        }.f },
        .{ .name = "runtime policy", .apply = struct {
            fn f(i: *Inputs) void {
                i.policy_section_digest = graph.digestBytes("other-policy-bytes");
            }
        }.f },
        .{ .name = "module order", .apply = struct {
            fn f(i: *Inputs) void {
                i.module_specifiers = &.{ "./helper.ts", "zttp:json" };
            }
        }.f },
        .{ .name = "core grammar", .apply = struct {
            fn f(i: *Inputs) void {
                i.core_grammar_hash = [_]u8{0xA2} ** 32;
            }
        }.f },
        .{ .name = "semantics", .apply = struct {
            fn f(i: *Inputs) void {
                i.semantics_hash = [_]u8{0xB3} ** 32;
            }
        }.f },
        .{ .name = "capabilities", .apply = struct {
            fn f(i: *Inputs) void {
                i.capability_hash = [_]u8{0xC4} ** 32;
            }
        }.f },
        .{ .name = "source profile", .apply = struct {
            fn f(i: *Inputs) void {
                i.core_profile_id = "zts-tsx-1";
            }
        }.f },
        .{ .name = "proof ir", .apply = struct {
            fn f(i: *Inputs) void {
                i.proof_ir_digest = [_]u8{0xD5} ** 32;
            }
        }.f },
        .{ .name = "proof certificate", .apply = struct {
            fn f(i: *Inputs) void {
                i.proof_certificate_digest = [_]u8{0xE6} ** 32;
            }
        }.f },
    };

    for (mutations) |mutation| {
        var inputs = sampleInputs(main, &deps);
        mutation.apply(&inputs);
        const mutated_out = try allocator.alloc(Member, max_members);
        defer allocator.free(mutated_out);
        const mutated = (try buildRoot(allocator, inputs, mutated_out)).root;
        testing.expect(!std.mem.eql(u8, &base, &mutated)) catch |err| {
            std.debug.print("mutation '{s}' did not move the root\n", .{mutation.name});
            return err;
        };
    }
}

test "mutating a nested function or a dependency moves the root" {
    const allocator = testing.allocator;
    var main_buf: [4096]u8 = undefined;
    var dep_buf: [4096]u8 = undefined;
    var other_buf: [4096]u8 = undefined;
    const main = try test_support.moduleBlob(allocator, 0x10, &main_buf);
    const dep = try test_support.moduleBlob(allocator, 0x20, &dep_buf);
    const deps = [_][]const u8{dep};
    const other_dep = try test_support.moduleBlob(allocator, 0x21, &other_buf);
    const other_deps = [_][]const u8{other_dep};

    const out = try allocator.alloc(Member, max_members);
    defer allocator.free(out);
    const base = (try buildRoot(allocator, sampleInputs(main, &deps), out)).root;

    const swapped_dep = try allocator.alloc(Member, max_members);
    defer allocator.free(swapped_dep);
    const with_other = (try buildRoot(allocator, sampleInputs(main, &other_deps), swapped_dep)).root;
    try testing.expect(!std.mem.eql(u8, &base, &with_other));

    // A single byte inside the main module's nested function.
    var tampered_buf: [4096]u8 = undefined;
    @memcpy(tampered_buf[0..main.len], main);
    var spans: [8]zts.bytecode_cache.ExecutableSpan = undefined;
    const count = try zts.bytecode_cache.walkExecutableSpans(main, &spans);
    try testing.expectEqual(@as(usize, 2), count);
    tampered_buf[spans[1].code_start] +%= 1;

    const tampered_out = try allocator.alloc(Member, max_members);
    defer allocator.free(tampered_out);
    const tampered = (try buildRoot(allocator, sampleInputs(tampered_buf[0..main.len], &deps), tampered_out)).root;
    try testing.expect(!std.mem.eql(u8, &base, &tampered));
}

test "a malformed module blob is refused rather than committed in part" {
    const allocator = testing.allocator;
    var main_buf: [4096]u8 = undefined;
    var dep_buf: [4096]u8 = undefined;
    const main = try test_support.moduleBlob(allocator, 0x10, &main_buf);
    const dep = try test_support.moduleBlob(allocator, 0x20, &dep_buf);
    const deps = [_][]const u8{dep};

    const out = try allocator.alloc(Member, max_members);
    defer allocator.free(out);
    try testing.expectError(
        error.MalformedBytecodeStream,
        build(allocator, sampleInputs(main[0 .. main.len - 3], &deps), out),
    );
}

test "an inventory larger than the artifact bound is refused" {
    const allocator = testing.allocator;
    var main_buf: [4096]u8 = undefined;
    var dep_buf: [4096]u8 = undefined;
    const main = try test_support.moduleBlob(allocator, 0x10, &main_buf);
    const dep = try test_support.moduleBlob(allocator, 0x20, &dep_buf);
    const deps = [_][]const u8{dep};

    const tiny = try allocator.alloc(Member, 3);
    defer allocator.free(tiny);
    try testing.expectError(
        error.TooManyMembers,
        build(allocator, sampleInputs(main, &deps), tiny),
    );
}

test "an artifact without a proof IR omits the member rather than zeroing it" {
    const allocator = testing.allocator;
    var main_buf: [4096]u8 = undefined;
    var dep_buf: [4096]u8 = undefined;
    const main = try test_support.moduleBlob(allocator, 0x10, &main_buf);
    const dep = try test_support.moduleBlob(allocator, 0x20, &dep_buf);
    const deps = [_][]const u8{dep};

    var inputs = sampleInputs(main, &deps);
    inputs.proof_ir_digest = null;
    const out = try allocator.alloc(Member, max_members);
    defer allocator.free(out);
    const members = try build(allocator, inputs, out);
    for (members) |member| {
        try testing.expect(member.kind != .proof_ir);
    }
    try testing.expectError(error.MissingRequiredKind, graph.checkRequiredKinds(members));
}

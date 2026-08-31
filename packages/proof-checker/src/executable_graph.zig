//! The canonical executable graph: one commitment over every byte and identity
//! that can affect what a deployment executes.
//!
//! A certificate over the main bytecode alone leaves the dependency modules,
//! the nested functions, and the constant pools outside the theorem boundary,
//! and all three run. The graph closes that: each authority-bearing section is
//! serialized once, hashed as those exact bytes, and folded into one root over
//! an ordered member inventory.
//!
//! The root is domain-separated and binds each member's kind and ordinal
//! alongside its digest, so identical bytes in two roles are two members and a
//! contract cannot be replayed as bytecode.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const domain = "zttp-executable-graph-v1";

/// The member alphabet. Closed: a new byte class that reaches execution needs a
/// member kind here and a producer that emits it, not a default bucket.
pub const MemberKind = enum(u16) {
    /// The entry module's bytecode, exactly as embedded.
    main_bytecode = 1,
    /// One dependency module's bytecode, in load order.
    dep_bytecode = 2,
    /// A nested function body reachable from a module, in definition order.
    nested_function = 3,
    /// A module's constant pool, serialized once.
    constant_pool = 4,
    /// One module specifier, in the contract's declared order.
    module_identity = 5,
    /// One native (virtual) module binding identity.
    native_module_identity = 6,
    /// The serialized handler contract.
    contract_bytes = 7,
    /// The serialized runtime policy.
    runtime_policy_bytes = 8,
    /// The core source profile identity.
    source_profile_core = 9,
    /// The frontend source profile identity, when the handler used one.
    source_profile_frontend = 10,
    /// The core grammar identity.
    core_grammar = 11,
    /// The semantics registry identity.
    semantics = 12,
    /// The capability matrix identity.
    capability_matrix = 13,
    /// The canonical proof IR the certificate carries.
    proof_ir = 14,
    /// The complete certificate with recursive root fields normalized.
    proof_certificate = 15,
    /// The canonical residual guard plan. Committed separately from the
    /// certificate that contains it so a mutated plan names itself rather than
    /// surfacing as a whole-certificate mismatch.
    residual_plan = 16,

    pub fn fromWire(value: u16) ?MemberKind {
        return switch (value) {
            1 => .main_bytecode,
            2 => .dep_bytecode,
            3 => .nested_function,
            4 => .constant_pool,
            5 => .module_identity,
            6 => .native_module_identity,
            7 => .contract_bytes,
            8 => .runtime_policy_bytes,
            9 => .source_profile_core,
            10 => .source_profile_frontend,
            11 => .core_grammar,
            12 => .semantics,
            13 => .capability_matrix,
            14 => .proof_ir,
            15 => .proof_certificate,
            16 => .residual_plan,
            else => null,
        };
    }

    pub fn name(self: MemberKind) []const u8 {
        return @tagName(self);
    }

    /// Kinds a production artifact must always carry. A graph missing one of
    /// these is not a smaller handler, it is an incomplete commitment.
    pub fn required(self: MemberKind) bool {
        return switch (self) {
            .main_bytecode,
            .contract_bytes,
            .runtime_policy_bytes,
            .source_profile_core,
            .core_grammar,
            .semantics,
            .capability_matrix,
            .proof_ir,
            .proof_certificate,
            => true,
            .dep_bytecode,
            .nested_function,
            .constant_pool,
            .module_identity,
            .native_module_identity,
            .source_profile_frontend,
            // Present only when the handler has guarded operations. An artifact
            // with none must not be forced to commit an empty plan, because an
            // empty plan and no plan are the same statement and one of them
            // would then be required.
            .residual_plan,
            => false,
        };
    }
};

pub const Member = struct {
    kind: MemberKind,
    /// Position within the kind, in the deterministic order the producer loads
    /// or declares them. Zero for kinds that occur once.
    ordinal: u32,
    /// SHA-256 of the exact bytes serialized for this member.
    digest: [32]u8,

    pub fn order(a: Member, b: Member) std.math.Order {
        const ka = @intFromEnum(a.kind);
        const kb = @intFromEnum(b.kind);
        if (ka != kb) return std.math.order(ka, kb);
        return std.math.order(a.ordinal, b.ordinal);
    }
};

pub const Error = error{
    EmptyGraph,
    NotOrdered,
    DuplicateMember,
    MissingRequiredKind,
    ZeroCommitment,
};

/// SHA-256 over the exact bytes of one member. Producers hash the same buffer
/// they embed; the consumer hashes the same buffer it loads.
pub fn digestBytes(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Sha256.hash(bytes, &out, .{});
    return out;
}

/// Streaming root computation.
///
/// The consumer folds members as it reads them, so a certificate carrying
/// thousands of dependency members never has to be materialized. Ordering,
/// duplication, and the declared count are all enforced during the fold, which
/// is what makes the resulting root a commitment to the inventory and not only
/// to the digests in it.
pub const RootHasher = struct {
    hasher: Sha256,
    previous: ?Member = null,
    seen_kinds: std.EnumSet(MemberKind) = std.EnumSet(MemberKind).initEmpty(),
    remaining: u32,

    pub fn init(count: u32) Error!RootHasher {
        if (count == 0) return error.EmptyGraph;
        var hasher = Sha256.init(.{});
        hasher.update(domain);
        var count_le: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_le, count, .little);
        hasher.update(&count_le);
        return .{ .hasher = hasher, .remaining = count };
    }

    pub fn push(self: *RootHasher, member: Member) Error!void {
        if (self.remaining == 0) return error.NotOrdered;
        if (self.previous) |prev| {
            switch (Member.order(prev, member)) {
                .lt => {},
                .eq => return error.DuplicateMember,
                .gt => return error.NotOrdered,
            }
        }
        self.previous = member;
        self.seen_kinds.insert(member.kind);
        self.remaining -= 1;

        var kind_le: [2]u8 = undefined;
        std.mem.writeInt(u16, &kind_le, @intFromEnum(member.kind), .little);
        var ordinal_le: [4]u8 = undefined;
        std.mem.writeInt(u32, &ordinal_le, member.ordinal, .little);

        self.hasher.update(&kind_le);
        self.hasher.update(&ordinal_le);
        self.hasher.update(&member.digest);
    }

    /// Every kind a production artifact must commit was pushed.
    pub fn checkRequiredKinds(self: RootHasher) Error!void {
        inline for (@typeInfo(MemberKind).@"enum".fields) |field| {
            const kind: MemberKind = @enumFromInt(field.value);
            if (kind.required() and !self.seen_kinds.contains(kind)) return error.MissingRequiredKind;
        }
    }

    pub fn finish(self: *RootHasher) Error![32]u8 {
        if (self.remaining != 0) return error.NotOrdered;
        const root = self.hasher.finalResult();
        if (std.mem.allEqual(u8, &root, 0)) return error.ZeroCommitment;
        return root;
    }
};

/// Fold an ordered member inventory into one root.
///
/// Refuses an empty graph, a member out of canonical order, and a duplicate
/// (kind, ordinal). Ordering is part of the commitment, so a producer cannot
/// reshuffle members and keep the root.
pub fn computeRoot(members: []const Member) Error![32]u8 {
    var hasher = try RootHasher.init(@intCast(members.len));
    for (members) |member| try hasher.push(member);
    return hasher.finish();
}

/// Whether the inventory carries every kind a production artifact must commit.
pub fn checkRequiredKinds(members: []const Member) Error!void {
    var hasher = try RootHasher.init(@intCast(members.len));
    for (members) |member| try hasher.push(member);
    try hasher.checkRequiredKinds();
}

const testing = std.testing;

fn m(kind: MemberKind, ordinal: u32, seed: u8) Member {
    var digest: [32]u8 = undefined;
    @memset(&digest, seed);
    return .{ .kind = kind, .ordinal = ordinal, .digest = digest };
}

fn fullGraph(buf: *[9]Member) []Member {
    buf.* = .{
        m(.main_bytecode, 0, 1),
        m(.contract_bytes, 0, 2),
        m(.runtime_policy_bytes, 0, 3),
        m(.source_profile_core, 0, 4),
        m(.core_grammar, 0, 5),
        m(.semantics, 0, 6),
        m(.capability_matrix, 0, 7),
        m(.proof_ir, 0, 8),
        m(.proof_certificate, 0, 9),
    };
    std.mem.sort(Member, buf, {}, struct {
        fn lt(_: void, a: Member, b: Member) bool {
            return Member.order(a, b) == .lt;
        }
    }.lt);
    return buf[0..];
}

test "an empty graph is not a commitment" {
    try testing.expectError(error.EmptyGraph, computeRoot(&[_]Member{}));
}

test "root is stable and order-sensitive" {
    var buf: [9]Member = undefined;
    const members = fullGraph(&buf);
    const root_a = try computeRoot(members);
    const root_b = try computeRoot(members);
    try testing.expectEqualSlices(u8, &root_a, &root_b);

    var swapped: [9]Member = undefined;
    @memcpy(&swapped, members);
    std.mem.swap(Member, &swapped[0], &swapped[1]);
    try testing.expectError(error.NotOrdered, computeRoot(&swapped));
}

test "a duplicate member is refused" {
    const dup = [_]Member{ m(.dep_bytecode, 0, 9), m(.dep_bytecode, 0, 9) };
    try testing.expectError(error.DuplicateMember, computeRoot(&dup));
}

test "mutating any member class changes the root" {
    var buf: [9]Member = undefined;
    const members = fullGraph(&buf);
    const base = try computeRoot(members);

    for (members, 0..) |_, idx| {
        var mutated: [9]Member = undefined;
        @memcpy(&mutated, members);
        mutated[idx].digest[0] +%= 1;
        const changed = try computeRoot(&mutated);
        try testing.expect(!std.mem.eql(u8, &base, &changed));
    }
}

test "adding a dependency member changes the root" {
    var buf: [9]Member = undefined;
    const members = fullGraph(&buf);
    const base = try computeRoot(members);

    var extended: [10]Member = undefined;
    @memcpy(extended[0..9], members);
    extended[9] = m(.dep_bytecode, 0, 42);
    std.mem.sort(Member, &extended, {}, struct {
        fn lt(_: void, a: Member, b: Member) bool {
            return Member.order(a, b) == .lt;
        }
    }.lt);
    const changed = try computeRoot(&extended);
    try testing.expect(!std.mem.eql(u8, &base, &changed));
}

test "required kinds must all be present" {
    var buf: [9]Member = undefined;
    const members = fullGraph(&buf);
    try checkRequiredKinds(members);
    try testing.expectError(error.MissingRequiredKind, checkRequiredKinds(members[0 .. members.len - 1]));
}

test "member kind wire decoding is closed" {
    try testing.expectEqual(@as(?MemberKind, null), MemberKind.fromWire(0));
    try testing.expectEqual(@as(?MemberKind, null), MemberKind.fromWire(17));
    inline for (@typeInfo(MemberKind).@"enum".fields) |field| {
        const kind: MemberKind = @enumFromInt(field.value);
        try testing.expectEqual(@as(?MemberKind, kind), MemberKind.fromWire(field.value));
    }
}

test "digestBytes is the plain content hash" {
    const bytes = "the exact bytes that execute";
    var expected: [32]u8 = undefined;
    Sha256.hash(bytes, &expected, .{});
    try testing.expectEqualSlices(u8, &expected, &digestBytes(bytes));
}

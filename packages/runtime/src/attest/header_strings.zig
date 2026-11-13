//! Proof receipt response headers.
//!
//! Precomputes the two response header values exactly once, at runtime
//! startup, so the per-request cost is one `writer.print` per header:
//!
//!   Zttp-Proofs: checked=results_checked; accepted=read_only; claimed=pure, ...
//!   Zttp-Attest: sha256=<64 lowercase hex, SHA-256 of the compact JWS>
//!
//! Field set and emission order are fixed (`chip_field_names` below). Only
//! claimed or accepted properties appear, in three groups by checker verdict;
//! an empty value signals "do not emit Zttp-Proofs."
//! `has_egress` and `max_io_depth` are intentionally excluded: the header
//! advertises positive proof claims to external consumers, not facts about
//! the handler's I/O surface.

const std = @import("std");
const zts = @import("zts");
const pcc = @import("zttp_proof_checker");
const contract_runtime = @import("../contract_runtime.zig");

/// Wire names for the two HTTP headers slice 1 emits. Single source of truth
/// so the writer (`server.zig:appendAttestationHeaders`) and the reader
/// (`verify_cli.zig:fetchAttestHeader`) can't drift on capitalization.
pub const header_name_proofs: []const u8 = "Zttp-Proofs";
pub const header_name_attest: []const u8 = "Zttp-Attest";

/// Prefix of the `Zttp-Attest` value, before the lowercase hex SHA-256 of the JWS.
pub const attest_digest_prefix: []const u8 = "sha256=";

pub const chip_field_names = [_][]const u8{
    "pure",
    "read_only",
    "stateless",
    "retry_safe",
    "deterministic",
    "no_secret_leakage",
    "no_credential_leakage",
    "input_validated",
    "pii_contained",
    "injection_safe",
    "idempotent",
    "state_isolated",
    "fault_covered",
    "result_safe",
    "optional_safe",
};

// `chip_field_names` is the header's fixed field set. A new `HandlerProperties` field is a chip or
// is named here.
const not_chips = zts.HandlerProperties.exclusions(
    &.{ "has_egress", "max_io_depth" },
    "the header advertises positive proof claims, not facts about the I/O surface",
) ++ zts.HandlerProperties.exclusions(
    &.{ "post_only", "canonical", "cost_bounded" },
    "outside the header's fixed field set",
);

comptime {
    if (zts.HandlerProperties.namesCoverageProblem("header_strings.chip_field_names", &chip_field_names, &not_chips)) |problem| @compileError(problem);
}

/// The `Zttp-Attest` value: `attest_digest_prefix` and the lowercase hex SHA-256
/// of the compact JWS. The JWS itself is served at `/.well-known/zttp-attest`.
pub fn attestDigest(allocator: std.mem.Allocator, jws_compact: []const u8) std.mem.Allocator.Error![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(jws_compact, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ attest_digest_prefix, &hex });
}

pub const HeaderStrings = struct {
    /// Empty slice means the runtime should not emit `Zttp-Proofs` at all
    /// (no chips were proven). `attest_value` is always present when this
    /// struct is built.
    proofs_value: []const u8,
    attest_value: []const u8,

    pub fn deinit(self: *HeaderStrings, allocator: std.mem.Allocator) void {
        if (self.proofs_value.len > 0) allocator.free(self.proofs_value);
        allocator.free(self.attest_value);
    }
};

/// The three disjoint proof groups of the `Zttp-Proofs` header and of the
/// startup log. Each field is an owned, comma-and-space-joined name list, empty
/// when the group has no member.
pub const Grades = struct {
    /// Kernel properties that the checker accepted and derived again.
    checked: []const u8,
    /// Kernel properties that the checker accepted without deriving them again.
    accepted: []const u8,
    /// Compiler claims (chip names) that the accepted chips do not hold.
    claimed: []const u8,

    pub fn deinit(self: *Grades, allocator: std.mem.Allocator) void {
        allocator.free(self.checked);
        allocator.free(self.accepted);
        allocator.free(self.claimed);
    }
};

/// Group each property by the checker verdict. `claims` is a struct with `bool`
/// fields matching `chip_field_names`. `proof` is null when no certificate was
/// accepted: every claim is then in `claimed`.
pub fn grade(
    allocator: std.mem.Allocator,
    claims: anytype,
    proof: ?*const contract_runtime.ProofCheckedContract,
) !Grades {
    var checked: std.ArrayList(u8) = .empty;
    errdefer checked.deinit(allocator);
    var accepted: std.ArrayList(u8) = .empty;
    errdefer accepted.deinit(allocator);
    var claimed: std.ArrayList(u8) = .empty;
    errdefer claimed.deinit(allocator);

    if (proof) |p| {
        inline for (@typeInfo(pcc.proof_system.Property).@"enum".field_names) |field| {
            const property = @field(pcc.proof_system.Property, field);
            if (p.verdicts.accepted(property)) {
                try appendName(allocator, if (p.verdicts.consumerChecked(property)) &checked else &accepted, field);
            }
        }
    }
    inline for (chip_field_names) |name| {
        const held = if (proof) |p| readBoolField(p.properties, name) else false;
        if (readBoolField(claims, name) and !held) try appendName(allocator, &claimed, name);
    }

    const checked_owned = try checked.toOwnedSlice(allocator);
    errdefer allocator.free(checked_owned);
    const accepted_owned = try accepted.toOwnedSlice(allocator);
    errdefer allocator.free(accepted_owned);
    return .{
        .checked = checked_owned,
        .accepted = accepted_owned,
        .claimed = try claimed.toOwnedSlice(allocator),
    };
}

fn appendName(allocator: std.mem.Allocator, list: *std.ArrayList(u8), name: []const u8) !void {
    if (list.items.len > 0) try list.appendSlice(allocator, ", ");
    try list.appendSlice(allocator, name);
}

/// `checked=...; accepted=...; claimed=...` with each empty group left out.
/// Empty slice when all three groups are empty.
fn formatGrades(allocator: std.mem.Allocator, grades: Grades) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const labels = [_][]const u8{ "checked=", "accepted=", "claimed=" };
    const lists = [_][]const u8{ grades.checked, grades.accepted, grades.claimed };
    for (labels, lists) |label, list| {
        if (list.len == 0) continue;
        if (out.items.len > 0) try out.appendSlice(allocator, "; ");
        try out.appendSlice(allocator, label);
        try out.appendSlice(allocator, list);
    }
    return out.toOwnedSlice(allocator);
}

/// `claims` must be a struct with `bool` fields matching `chip_field_names`.
/// Missing fields are treated as `false`. `proof` is the accepted certificate
/// of the running artifact, or null. `proofs_value` is the graded list.
pub fn build(
    allocator: std.mem.Allocator,
    claims: anytype,
    proof: ?*const contract_runtime.ProofCheckedContract,
    jws_compact: []const u8,
) !HeaderStrings {
    var grades = try grade(allocator, claims, proof);
    defer grades.deinit(allocator);
    const proofs_value = try formatGrades(allocator, grades);
    errdefer if (proofs_value.len > 0) allocator.free(proofs_value);

    const attest_value = try attestDigest(allocator, jws_compact);

    return .{
        .proofs_value = proofs_value,
        .attest_value = attest_value,
    };
}

/// Comma-and-space-joined list of `true` chip field names in
/// `chip_field_names` order. Empty slice when no chip is proven. Exposed so
/// the compile-time signer can put the same string into signed claims that
/// the runtime later emits as a header.
pub fn formatProofChips(allocator: std.mem.Allocator, props: anytype) ![]const u8 {
    var total_len: usize = 0;
    var count: usize = 0;
    inline for (chip_field_names) |name| {
        if (readBoolField(props, name)) {
            total_len += name.len;
            count += 1;
        }
    }
    if (count == 0) return "";
    total_len += (count - 1) * 2; // ", " separators

    var buf = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    var emitted: usize = 0;
    inline for (chip_field_names) |name| {
        if (readBoolField(props, name)) {
            if (emitted > 0) {
                buf[pos] = ',';
                buf[pos + 1] = ' ';
                pos += 2;
            }
            @memcpy(buf[pos .. pos + name.len], name);
            pos += name.len;
            emitted += 1;
        }
    }
    return buf;
}

fn readBoolField(props: anytype, comptime name: []const u8) bool {
    const T = @TypeOf(props);
    if (!@hasField(T, name)) return false;
    return @field(props, name);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestProps = struct {
    pure: bool = false,
    read_only: bool = false,
    stateless: bool = false,
    retry_safe: bool = false,
    deterministic: bool = false,
    no_secret_leakage: bool = false,
    no_credential_leakage: bool = false,
    input_validated: bool = false,
    pii_contained: bool = false,
    injection_safe: bool = false,
    idempotent: bool = false,
    state_isolated: bool = false,
    fault_covered: bool = false,
    result_safe: bool = false,
    optional_safe: bool = false,
    // Fields header_strings deliberately ignores:
    has_egress: bool = false,
    max_io_depth: ?u32 = null,
};

test "all-false props produce an empty proofs value" {
    const allocator = std.testing.allocator;
    var hs = try build(allocator, TestProps{}, null, "h.p.s");
    defer hs.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), hs.proofs_value.len);
    try std.testing.expectEqualStrings("sha256=300a2664bcbaa90b9eaceffbb7e40f019a2cc9b050b7bc8d148d4cd7c28df5d9", hs.attest_value);
}

test "single claimed chip emits exactly that name under claimed" {
    const allocator = std.testing.allocator;
    var hs = try build(allocator, TestProps{ .injection_safe = true }, null, "jws");
    defer hs.deinit(allocator);

    try std.testing.expectEqualStrings("claimed=injection_safe", hs.proofs_value);
}

test "claimed chips join with comma-space in declared order" {
    const allocator = std.testing.allocator;
    var hs = try build(
        allocator,
        TestProps{
            .pure = true,
            .read_only = true,
            .injection_safe = true,
            .no_secret_leakage = true,
            .deterministic = true,
        },
        null,
        "jws",
    );
    defer hs.deinit(allocator);

    try std.testing.expectEqualStrings(
        "claimed=pure, read_only, deterministic, no_secret_leakage, injection_safe",
        hs.proofs_value,
    );
}

test "has_egress is excluded from the public header" {
    const allocator = std.testing.allocator;
    var hs = try build(
        allocator,
        TestProps{ .has_egress = true, .pure = true },
        null,
        "jws",
    );
    defer hs.deinit(allocator);

    try std.testing.expectEqualStrings("claimed=pure", hs.proofs_value);
}

test "structs missing chip fields treat them as false" {
    const allocator = std.testing.allocator;
    const Partial = struct {
        pure: bool = true,
        injection_safe: bool = true,
    };
    var hs = try build(allocator, Partial{}, null, "jws");
    defer hs.deinit(allocator);

    try std.testing.expectEqualStrings("claimed=pure, injection_safe", hs.proofs_value);
}

test "attest_value is the digest of the JWS and does not alias it" {
    const allocator = std.testing.allocator;
    var jws_buf: [16]u8 = .{ 'a', 'b', 'c', '.', 'd', 'e', 'f', '.', 'g', 'h', 'i', 0, 0, 0, 0, 0 };
    var hs = try build(allocator, TestProps{}, null, jws_buf[0..11]);
    defer hs.deinit(allocator);

    @memset(jws_buf[0..11], 'X');
    try std.testing.expectEqualStrings("sha256=6559e90b5dd57405bdf180f29b509053a3d36c4abf3de535ab249b54d4327234", hs.attest_value);
}

test "chip_field_names matches the public contract length" {
    try std.testing.expectEqual(@as(usize, 15), chip_field_names.len);
}

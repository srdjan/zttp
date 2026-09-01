//! How guard coverage is written down, wherever a surface reports it.
//!
//! Guard coverage is the third axis beside proof stages and property verdicts,
//! and the reason it gets its own renderer is that every surface has to say the
//! same thing about it: how many operations the consumer reconstructed, how
//! many the certificate covered, and which kinds they were. What none of them
//! may do is add a covered guard to the proven set. A covered guard is a
//! promise to check a value at run time. It is not a theorem about the program,
//! and a surface that folds the two together tells a reader the artifact proved
//! something it only agreed to watch.

const std = @import("std");
const pcc = @import("zttp_proof_checker");

pub const GuardVerdicts = pcc.verdict.GuardVerdicts;

/// The kinds present, comma-joined, in catalog order. Empty when none.
///
/// Bounded by construction: five kinds, each named by a fixed string, so the
/// longest possible result is known at compile time and no input can grow it.
pub const max_kinds_bytes: usize = blk: {
    var total: usize = 0;
    for (@typeInfo(pcc.residual.GuardKind).@"enum".fields) |field| {
        total += field.name.len + 1;
    }
    break :blk total;
};

pub fn writeKinds(writer: *std.Io.Writer, kinds: u8) std.Io.Writer.Error!void {
    var wrote_any = false;
    inline for (@typeInfo(pcc.residual.GuardKind).@"enum".fields) |field| {
        const kind: pcc.residual.GuardKind = @enumFromInt(field.value);
        if (kinds & (@as(u8, 1) << @intCast(field.value - 1)) != 0) {
            if (wrote_any) try writer.writeAll(", ");
            try writer.writeAll(kind.name());
            wrote_any = true;
        }
    }
}

/// `writeKinds` into a caller-owned buffer, for a surface that needs a slice.
pub fn kindsText(buffer: *[max_kinds_bytes]u8, kinds: u8) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    writeKinds(&writer, kinds) catch return "";
    return writer.buffered();
}

/// One line, for a surface whose reader is a person.
///
/// Says "none" rather than "0 of 0" for an artifact with nothing to guard,
/// because those read differently: the first is a fact about the handler, the
/// second invites the reader to wonder what went missing.
pub fn writeSummary(writer: *std.Io.Writer, verdicts: GuardVerdicts) std.Io.Writer.Error!void {
    if (verdicts.required == 0) {
        try writer.writeAll("none - this artifact has no guarded operation");
        return;
    }
    try writer.print("{d} of {d} covered (", .{ verdicts.covered, verdicts.required });
    try writeKinds(writer, verdicts.kinds);
    try writer.writeAll("); checked at run time, never part of the proven set");
}

const testing = std.testing;

test "kinds are named in catalog order and none is invented" {
    var buffer: [max_kinds_bytes]u8 = undefined;
    try testing.expectEqualStrings("", kindsText(&buffer, 0));
    try testing.expectEqualStrings("env_key", kindsText(&buffer, 0b0000_0001));
    try testing.expectEqualStrings(
        "env_key, cache_namespace",
        kindsText(&buffer, 0b0000_0101),
    );
    // A bit outside the alphabet names nothing rather than printing a number.
    try testing.expectEqualStrings("", kindsText(&buffer, 0b1000_0000));
}

test "a summary says none rather than zero of zero" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeSummary(&writer, .{});
    try testing.expectEqualStrings("none - this artifact has no guarded operation", writer.buffered());

    var second: [256]u8 = undefined;
    var writer_two = std.Io.Writer.fixed(&second);
    try writeSummary(&writer_two, .{ .required = 2, .covered = 2, .kinds = 0b0000_0011 });
    try testing.expectEqualStrings(
        "2 of 2 covered (env_key, egress_endpoint); checked at run time, never part of the proven set",
        writer_two.buffered(),
    );
}

test "an uncovered guard is visible in the summary" {
    // The number that matters when coverage fails: the surface must not round
    // it to "guarded" and move on.
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeSummary(&writer, .{ .required = 3, .covered = 1, .kinds = 0b0000_0100 });
    try testing.expectEqualStrings(
        "1 of 3 covered (cache_namespace); checked at run time, never part of the proven set",
        writer.buffered(),
    );
}

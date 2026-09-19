//! One human-readable rendering of application-invariant status.
//!
//! Every reader of an invariant status goes through this file: the offline
//! proof report in `proofs/bundle.zig` and the live startup line in
//! `server.zig` both call `writeSummary`, so a sentence added here reaches
//! both and a sentence that stops being true stops being printed in both.
//!
//! Three separations the rendering keeps, because collapsing any of them is
//! how a report comes to claim more than acceptance established:
//!
//! 1. Write applicability leads. Coverage counts call sites, not calls that
//!    executed, so "coverage 1 of 1" read first is read as "the conservation
//!    predicate ran". The value that says whether any covered call site can
//!    write is therefore the first thing in the line.
//! 2. Coverage is an acceptance result; baseline status is a later result from
//!    opening and validating the protected store. An offline report has not
//!    opened one and says so.
//! 3. Native enforcement is named as a trusted assumption. Acceptance never
//!    examines a predicate's behaviour, so nothing here may read as a check of
//!    one.
//!
//! Nothing rendered here is a proof of an application predicate, and no
//! author-supplied sentence is rendered at all. What the system establishes is
//! that the linked adapter carries a row per expected kind at the expected
//! version, that the declared call sites match the ones the loader found on
//! its own in final bytecode, and that a store validated its baseline when an
//! instance opened it.

const std = @import("std");
const pcc = @import("zttp_proof_checker");
const contract_runtime = @import("../contract_runtime.zig");

pub const InvariantStatus = contract_runtime.InvariantStatus;

/// The clause every rendering ends with, written once from outside every
/// branch in `writeSummary`.
///
/// The checker never opens the store and never sees who else can. A reader
/// deciding how much the numbers above are worth needs that fact whatever the
/// numbers say, so there is no argument, flag or status value that drops this.
const deployment_assumption =
    "; keeping other writers off a protected ledger store is always a deployment " ++
    "assumption, which this checker does not verify";

/// What an accepted artifact with no declared invariant renders.
///
/// This is the only artifact that reaches it. Both callers render an
/// acceptance: `proofs/bundle.zig` returns `error.ProofRejected` before the
/// invariant line, and `server.zig` renders a promoted contract, which only
/// an accepted assessment produces. A refused artifact therefore never
/// arrives here, and this sentence does not hedge about one.
///
/// It could not hedge accurately in any case. A rejection at or before
/// invariant coverage does leave `InvariantVerdicts` at its defaults, but
/// `checker.zig`'s `run` assigns the coverage it reached onto a later
/// evidence-stage or solver-stage rejection, so a refused artifact does not
/// have one status - it has two, depending on how far it got.
const no_invariant_body =
    "not configured; this artifact declares no application invariant, so no kind, " ++
    "no coverage, no write applicability and no baseline apply";

/// A buffer size every rendering fits in. Callers render into a fixed buffer,
/// and a fixed writer that runs out truncates mid-sentence - which is one way
/// the clause above stops being printed. `the widest summary fits the bound
/// callers size their buffers from` holds this to the widest input the status
/// type admits.
pub const max_summary_bytes: usize = 768;

/// Render one artifact generation's invariant status.
///
/// The body is two statements on purpose: everything conditional happens in
/// `writeStatus`, and the deployment assumption is appended after it from
/// here, outside every branch. `zig build test-invariant-drift` pins these two
/// statements.
pub fn writeSummary(writer: *std.Io.Writer, status: InvariantStatus) std.Io.Writer.Error!void {
    try writeStatus(writer, status);
    try writer.writeAll(deployment_assumption);
}

fn writeStatus(writer: *std.Io.Writer, status: InvariantStatus) std.Io.Writer.Error!void {
    if (!status.configured) {
        try writer.writeAll(no_invariant_body);
        return;
    }
    try writer.print("write applicability {s}; kinds ", .{applicabilityText(status.write_applicability)});
    try writeDeclaredKinds(writer, status.kind_bits);
    try writer.print(
        "; coverage {d} of {d} protected call sites ({d} write, {d} read), " ++
            "each matched to a ledger call found independently in final bytecode; {s}; {s}",
        .{
            status.covered,
            status.required,
            status.writes,
            status.reads,
            nativeText(status.native_adapter_assumption),
            baselineText(status.runtime_readiness),
        },
    );
}

/// Name every kind the accepted specification declared.
///
/// The names come from the closed catalog through the bits acceptance carried
/// out, so a kind the specification did not declare cannot be named and a kind
/// it did declare cannot be omitted by this file forgetting to list it.
fn writeDeclaredKinds(writer: *std.Io.Writer, kind_bits: u32) std.Io.Writer.Error!void {
    var named_any = false;
    for (std.enums.values(pcc.invariant.Kind)) |kind| {
        if (kind_bits & pcc.invariant.kindBit(kind) == 0) continue;
        if (named_any) try writer.writeAll(", ");
        try writer.writeAll(@tagName(kind));
        named_any = true;
    }
    if (!named_any) try writer.writeAll("none recorded");
}

/// Each value says what it means in the same breath. `covered` alone reads as
/// a grade, and `vacuous` alone reads as a failure; neither is either.
fn applicabilityText(applicability: pcc.verdict.WriteApplicability) []const u8 {
    return switch (applicability) {
        .not_applicable => "not applicable",
        .vacuous => "vacuous - no covered call site can modify ledger state",
        .covered => "covered - a covered call site can modify ledger state",
    };
}

fn nativeText(assumption: contract_runtime.NativeAdapterAssumption) []const u8 {
    return switch (assumption) {
        .not_applicable => "native enforcement not applicable",
        .trusted => "native enforcement is a trusted assumption, not a checked one",
    };
}

/// Only a live instance that opened the store can report a validated
/// baseline. An offline report says which question it did not ask rather than
/// leaving the reader to assume it asked and got a good answer.
fn baselineText(readiness: contract_runtime.InvariantRuntimeReadiness) []const u8 {
    return switch (readiness) {
        .not_applicable => "ledger baseline not applicable",
        .not_checked => "ledger baseline not checked - this report did not open a store",
        .ready => "ledger baseline validated when this instance opened the store",
    };
}

const testing = std.testing;

const balance_bit = pcc.invariant.kindBit(.balance_conservation_v1);
const accounts_bit = pcc.invariant.kindBit(.declared_accounts_v1);

fn render(buffer: []u8, status: InvariantStatus) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writeSummary(&writer, status);
    return writer.buffered();
}

/// The four statuses this renderer can be handed, in one place so every test
/// below names the same artifact when it names a case.
///
/// There is no fixture for a refused artifact, because no refused artifact
/// reaches this file: both callers render an acceptance. A literal
/// `InvariantStatus{}` standing in for one would not be a fifth case either -
/// it is this same value, so a test over it could not fail independently of
/// the one below, and it would not even be the right value for a rejection
/// after invariant coverage, which carries the coverage it reached.
const unconfigured_status = InvariantStatus{};

const offline_status = InvariantStatus{
    .configured = true,
    .required = 2,
    .covered = 2,
    .writes = 1,
    .reads = 1,
    .write_applicability = .covered,
    .kind_bits = balance_bit,
    .native_adapter_assumption = .trusted,
    .runtime_readiness = .not_checked,
};

const read_only_status = InvariantStatus{
    .configured = true,
    .required = 1,
    .covered = 1,
    .writes = 0,
    .reads = 1,
    .write_applicability = .vacuous,
    .kind_bits = balance_bit,
    .native_adapter_assumption = .trusted,
    .runtime_readiness = .ready,
};

const ready_write_capable_status = InvariantStatus{
    .configured = true,
    .required = 2,
    .covered = 2,
    .writes = 1,
    .reads = 1,
    .write_applicability = .covered,
    .kind_bits = balance_bit | accounts_bit,
    .native_adapter_assumption = .trusted,
    .runtime_readiness = .ready,
};

/// The four above, for the checks that must hold of every rendering.
const every_case = [_]InvariantStatus{
    unconfigured_status,
    offline_status,
    read_only_status,
    ready_write_capable_status,
};

test "an accepted artifact with no declared invariant reports nothing applicable" {
    var buffer: [max_summary_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        "not configured; this artifact declares no application invariant, so no kind, " ++
            "no coverage, no write applicability and no baseline apply; " ++
            "keeping other writers off a protected ledger store is always a deployment " ++
            "assumption, which this checker does not verify",
        try render(&buffer, unconfigured_status),
    );
}

test "an offline proof report leads with write applicability and checks no baseline" {
    var buffer: [max_summary_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        "write applicability covered - a covered call site can modify ledger state; " ++
            "kinds balance_conservation_v1; " ++
            "coverage 2 of 2 protected call sites (1 write, 1 read), " ++
            "each matched to a ledger call found independently in final bytecode; " ++
            "native enforcement is a trusted assumption, not a checked one; " ++
            "ledger baseline not checked - this report did not open a store; " ++
            "keeping other writers off a protected ledger store is always a deployment " ++
            "assumption, which this checker does not verify",
        try render(&buffer, offline_status),
    );
}

test "a read-only instance reports vacuous applicability over a validated baseline" {
    var buffer: [max_summary_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        "write applicability vacuous - no covered call site can modify ledger state; " ++
            "kinds balance_conservation_v1; " ++
            "coverage 1 of 1 protected call sites (0 write, 1 read), " ++
            "each matched to a ledger call found independently in final bytecode; " ++
            "native enforcement is a trusted assumption, not a checked one; " ++
            "ledger baseline validated when this instance opened the store; " ++
            "keeping other writers off a protected ledger store is always a deployment " ++
            "assumption, which this checker does not verify",
        try render(&buffer, read_only_status),
    );
}

test "a ready write-capable instance names every declared kind" {
    var buffer: [max_summary_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        "write applicability covered - a covered call site can modify ledger state; " ++
            "kinds balance_conservation_v1, declared_accounts_v1; " ++
            "coverage 2 of 2 protected call sites (1 write, 1 read), " ++
            "each matched to a ledger call found independently in final bytecode; " ++
            "native enforcement is a trusted assumption, not a checked one; " ++
            "ledger baseline validated when this instance opened the store; " ++
            "keeping other writers off a protected ledger store is always a deployment " ++
            "assumption, which this checker does not verify",
        try render(&buffer, ready_write_capable_status),
    );
}

test "write applicability precedes the coverage counts in every configured rendering" {
    // The ordering the reports depend on, asserted over the rendered bytes
    // rather than over the format string, for each configured case.
    for ([_]InvariantStatus{ offline_status, read_only_status, ready_write_capable_status }) |status| {
        var buffer: [max_summary_bytes]u8 = undefined;
        const rendered = try render(&buffer, status);
        const applicability_at = std.mem.indexOf(u8, rendered, "write applicability ") orelse {
            std.debug.print("no write applicability in '{s}'\n", .{rendered});
            return error.TestExpectedEqual;
        };
        const coverage_at = std.mem.indexOf(u8, rendered, "coverage ") orelse {
            std.debug.print("no coverage counts in '{s}'\n", .{rendered});
            return error.TestExpectedEqual;
        };
        try testing.expectEqual(@as(usize, 0), applicability_at);
        try testing.expect(applicability_at < coverage_at);
    }
}

test "the deployment assumption closes every rendering, including the empty one" {
    // The clause is what a reader needs whatever the numbers above say, so the
    // check is over every case rather than over the one that motivated it.
    // Four is the set's size; shrinking it is a deliberate edit, and without
    // this the loop below would still pass over a set somebody emptied.
    try testing.expectEqual(@as(usize, 4), every_case.len);
    for (every_case) |status| {
        var buffer: [max_summary_bytes]u8 = undefined;
        const rendered = try render(&buffer, status);
        try testing.expectEqualStrings(
            "; keeping other writers off a protected ledger store is always a deployment " ++
                "assumption, which this checker does not verify",
            rendered[rendered.len - deployment_assumption.len ..],
        );
    }
}

test "no rendering claims an application predicate was proven" {
    // The whole feature's honesty is one property: a developer must never read
    // this line and conclude the system checked a predicate. Every word that
    // would carry that reading is refused here, over the bytes that ship.
    const forbidden = [_][]const u8{ "proven", "proved", "verified", "guaranteed", "enforced and checked" };
    for (every_case) |status| {
        var buffer: [max_summary_bytes]u8 = undefined;
        const rendered = try render(&buffer, status);
        for (forbidden) |word| {
            if (std.mem.indexOf(u8, rendered, word) != null) {
                std.debug.print("summary claims '{s}': {s}\n", .{ word, rendered });
                return error.TestExpectedEqual;
            }
        }
    }
    // A floor: the loop above passes over an empty corpus and over a renderer
    // that emits nothing at all. Every case must have produced a sentence that
    // names what was and was not established.
    var floor_buffer: [max_summary_bytes]u8 = undefined;
    const floor = try render(&floor_buffer, ready_write_capable_status);
    try testing.expect(std.mem.indexOf(u8, floor, "trusted assumption") != null);
    try testing.expect(std.mem.indexOf(u8, floor, "does not verify") != null);
}

test "the widest summary fits the bound callers size their buffers from" {
    // Callers render into `[max_summary_bytes]u8`. A fixed writer that runs
    // out stops mid-sentence, and the sentence it would stop before is the
    // deployment assumption, so the bound is load-bearing rather than
    // cosmetic. The widest input the status type admits: every catalog kind
    // declared, the longest branch of every segment, and counts at the width
    // a u32 can print.
    var widest = InvariantStatus{
        .configured = true,
        .required = std.math.maxInt(u32),
        .covered = std.math.maxInt(u32),
        .writes = std.math.maxInt(u32),
        .reads = std.math.maxInt(u32),
        .write_applicability = .vacuous,
        .kind_bits = 0,
        .native_adapter_assumption = .trusted,
        .runtime_readiness = .not_checked,
    };
    for (std.enums.values(pcc.invariant.Kind)) |kind| {
        widest.kind_bits |= pcc.invariant.kindBit(kind);
    }
    var buffer: [max_summary_bytes]u8 = undefined;
    const rendered = try render(&buffer, widest);
    for (std.enums.values(pcc.invariant.Kind)) |kind| {
        try testing.expect(std.mem.indexOf(u8, rendered, @tagName(kind)) != null);
    }
    try testing.expect(rendered.len <= max_summary_bytes);
}

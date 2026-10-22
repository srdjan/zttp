//! Census of the hand-kept field lists that surround `HandlerContract`.
//!
//! Three files copy the field list of `HandlerContract` by hand: the writer
//! (`contract_json_writer.zig`), the parser mirror `ContractWire`
//! (`contract_json_parser.zig`), and the differ (`contract_diff.zig`). A field
//! added to the type and forgotten in one of those files compiles. It then
//! reads as its default value, or it drops out of the diff.
//!
//! This file records one decision per field. `entries` says, for each
//! `HandlerContract` field, whether the wire carries it and whether
//! `diffContracts` compares it. `wire_entries` maps each `ContractWire` field
//! to the `HandlerContract` fields it fills, or marks it as a retired field
//! that the parser reads only to refuse it.
//!
//! The comptime checks fail the build on a field with no entry, on an entry
//! that names no field, and on a classification with no reason. The checks
//! prove that a decision exists. They do not prove that the writer, the
//! parser, or the differ acts on it. `contract_census.zig` checks the wire
//! side against golden bytes. The diff column is declared from a reading of
//! `diffContracts`, and nothing here executes the differ.
//!
//! A `diff_reason` starts with `design:` when the field has a reason not to
//! be compared, or with `gap:` when no reason is recorded. A gap is a finding
//! for the owner of the differ. This file records gaps and does not fix them.

const std = @import("std");
const contract_types = @import("contract_types.zig");

/// Whether the contract JSON carries the field.
pub const Wire = enum { serialized, not_serialized };

/// Whether `diffContracts` compares the field. `partly_diffed` means that some
/// part of the field is compared and the `diff_reason` names what is not.
pub const Diff = enum { diffed, partly_diffed, not_diffed };

pub const Entry = struct {
    /// A field name of `HandlerContract`.
    field: []const u8,
    wire: Wire,
    /// Required when `wire` is `not_serialized`, and empty otherwise.
    wire_reason: []const u8 = "",
    diff: Diff,
    /// Empty when `diff` is `diffed`. Otherwise it starts with `design: ` or `gap: `.
    diff_reason: []const u8 = "",
};

pub const entries = [_]Entry{
    .{
        .field = "version",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "design: the schema version marks the wire format and says nothing about handler behavior",
    },
    .{
        .field = "handler",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "design: path, line, and column locate the source and prove nothing about behavior",
    },
    .{
        .field = "routes",
        .wire = .serialized,
        .diff = .partly_diffed,
        .diff_reason = "gap: findRoute compares pattern, route_type, status, and content_type; field (path or url) and aot are not compared",
    },
    .{
        .field = "modules",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "gap: an added or removed import is not reported; egress, cache, sql, and env literals cover only what a module uses with a literal",
    },
    .{
        .field = "functions",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "gap: the imported function names are not compared",
    },
    .{ .field = "env", .wire = .serialized, .diff = .diffed },
    .{
        .field = "egress",
        .wire = .serialized,
        .diff = .partly_diffed,
        .diff_reason = "gap: endpoints and dynamic are compared; the full fetch urls are not",
    },
    .{ .field = "cache", .wire = .serialized, .diff = .diffed },
    .{ .field = "sql", .wire = .serialized, .diff = .diffed },
    .{
        .field = "api",
        .wire = .serialized,
        .diff = .partly_diffed,
        .diff_reason = "gap: routes, params, bodies, responses, route auth, and a route or schema surface going dynamic are compared; api.auth, api.requests, and schemas that no route references are not",
    },
    .{
        .field = "verification",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "gap: results_safe is covered only through properties.result_safe, and only when properties is set; the other verification flags are not compared",
    },
    .{
        .field = "aot",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "gap: the AOT pattern count and default flag are not compared",
    },
    .{
        .field = "fault_coverage",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "design: the property bit properties.fault_covered carries the outcome (see FaultCoverageInfo); the raw counts are informational",
    },
    .{
        .field = "rate_limiting",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "gap: the namespace is usually also in cache.namespaces, which is compared; the dynamic flag of the rate limit is not",
    },
    .{
        .field = "owned_rate_limit_namespace",
        .wire = .not_serialized,
        .wire_reason = "an allocation that backs rate_limiting.namespace after a decode; the namespace itself is written",
        .diff = .not_diffed,
        .diff_reason = "design: an ownership detail of a decoded contract, not a proven fact",
    },
    .{
        .field = "owned_fault_cause_snippet",
        .wire = .not_serialized,
        .wire_reason = "an allocation that backs a property_provenance snippet at check time; transient",
        .diff = .not_diffed,
        .diff_reason = "design: an ownership detail of the live check, not a proven fact",
    },
    .{
        .field = "properties",
        .wire = .serialized,
        .diff = .partly_diffed,
        .diff_reason = "gap: monotonic proven properties and max_io_depth are compared, and inverse facts such as has_egress are left out on purpose; nothing is compared when either contract has properties null",
    },
    .{
        .field = "effect_analysis_complete",
        .wire = .not_serialized,
        .wire_reason = "transient analysis state; the contract JSON does not emit it",
        .diff = .not_diffed,
        .diff_reason = "design: transient analysis state, not a proven fact",
    },
    .{
        .field = "intent",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "design: intent assertions are author examples outside the proof boundary (see IntentInfo)",
    },
    .{
        .field = "property_provenance",
        .wire = .not_serialized,
        .wire_reason = "in-memory provenance for the live-reload HUD; the contract JSON does not emit it",
        .diff = .not_diffed,
        .diff_reason = "design: display data for the HUD, not a proven fact",
    },
    .{
        .field = "declared_specs",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "gap: a narrower or wider declared Proof set is not reported",
    },
    .{
        .field = "declared_specs_implicit",
        .wire = .not_serialized,
        .wire_reason = "transient; recomputed on each build",
        .diff = .not_diffed,
        .diff_reason = "design: transient flag used only to word a diagnostic",
    },
    .{
        .field = "extensions",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "gap: an extension copies its egress hosts into egress.endpoints, which is compared; its category literals and dynamic flags are not",
    },
    .{
        .field = "spec_diagnostics",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "gap: the diagnostics derive from declared_specs and properties, but a new or cleared diagnostic is not reported",
    },
    .{
        .field = "function_capsules",
        .wire = .not_serialized,
        .wire_reason = "transient analysis output for the --json analysis envelope; the contract JSON does not emit it",
        .diff = .not_diffed,
        .diff_reason = "design: transient analysis output, not part of the signed surface",
    },
    .{
        .field = "function_effect_capsules",
        .wire = .not_serialized,
        .wire_reason = "transient analysis output for the --json analysis envelope; the contract JSON does not emit it",
        .diff = .not_diffed,
        .diff_reason = "design: transient analysis output, not part of the signed surface",
    },
    .{
        .field = "holes",
        .wire = .not_serialized,
        .wire_reason = "hole() call sites exist only for a program that is not finished; the contract JSON does not emit them",
        .diff = .not_diffed,
        .diff_reason = "design: transient analysis output for an unfinished program",
    },
    .{ .field = "behaviors", .wire = .serialized, .diff = .diffed },
    .{
        .field = "behaviors_exhaustive",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "gap: a change from exhaustive to truncated path enumeration is not reported",
    },
    .{
        .field = "cost_envelope",
        .wire = .serialized,
        .diff = .partly_diffed,
        .diff_reason = "gap: only the class of the total bound is compared (costClassOf); a larger constant, coefficient, or base inside one class, the per-module entries, and the exhaustive flag are not",
    },
    .{
        .field = "capabilities",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "gap: a widened capability matrix is not reported directly",
    },
    .{
        .field = "capability_budget",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "gap: a changed declared Effects budget is not reported",
    },
    .{
        .field = "source_identity",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "gap: a changed core profile or grammar hash is not reported",
    },
    .{
        .field = "artifact_sha256",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "design: a build stamp that changes with every code change, so a diff of it carries no information",
    },
    .{
        .field = "policy_hash",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "design: a build stamp of the rule registry, which describes the toolchain and not the handler",
    },
    .{
        .field = "wasm_policy_hash",
        .wire = .serialized,
        .diff = .not_diffed,
        .diff_reason = "design: a build stamp of the embedded policy artifact, which describes the toolchain and not the handler",
    },
};

/// Whether a `ContractWire` field fills `HandlerContract` fields or exists only to be refused.
pub const WireKind = enum { carries, retired_refused };

pub const WireEntry = struct {
    /// A field name of `ContractWire` (the version 1 spelling).
    wire_field: []const u8,
    kind: WireKind,
    /// The `HandlerContract` fields that this wire field fills. Empty for a retired field.
    targets: []const []const u8 = &.{},
    /// Required for a retired field: why the wire still names it.
    reason: []const u8 = "",
};

pub const retired_reason = "the field carried runtime authority that the beta removed; the parser reads it only so rejectRetiredFields can refuse a document that holds it";

pub const wire_entries = [_]WireEntry{
    .{ .wire_field = "version", .kind = .carries, .targets = &.{"version"} },
    .{ .wire_field = "handler", .kind = .carries, .targets = &.{"handler"} },
    .{ .wire_field = "sourceIdentity", .kind = .carries, .targets = &.{"source_identity"} },
    .{ .wire_field = "routes", .kind = .carries, .targets = &.{"routes"} },
    .{ .wire_field = "modules", .kind = .carries, .targets = &.{"modules"} },
    .{ .wire_field = "functions", .kind = .carries, .targets = &.{"functions"} },
    .{ .wire_field = "env", .kind = .carries, .targets = &.{"env"} },
    .{ .wire_field = "egress", .kind = .carries, .targets = &.{"egress"} },
    .{ .wire_field = "serviceCalls", .kind = .retired_refused, .reason = retired_reason },
    .{ .wire_field = "workflowCalls", .kind = .retired_refused, .reason = retired_reason },
    .{ .wire_field = "affordances", .kind = .retired_refused, .reason = retired_reason },
    .{ .wire_field = "affordancesDynamic", .kind = .retired_refused, .reason = retired_reason },
    .{ .wire_field = "tools", .kind = .retired_refused, .reason = retired_reason },
    .{ .wire_field = "toolAuth", .kind = .retired_refused, .reason = retired_reason },
    .{ .wire_field = "credentials", .kind = .retired_refused, .reason = retired_reason },
    .{ .wire_field = "classifications", .kind = .retired_refused, .reason = retired_reason },
    .{ .wire_field = "ceiling", .kind = .retired_refused, .reason = retired_reason },
    .{ .wire_field = "cache", .kind = .carries, .targets = &.{"cache"} },
    .{ .wire_field = "sql", .kind = .carries, .targets = &.{"sql"} },
    .{ .wire_field = "durable", .kind = .retired_refused, .reason = retired_reason },
    .{ .wire_field = "scope", .kind = .retired_refused, .reason = retired_reason },
    .{ .wire_field = "api", .kind = .carries, .targets = &.{"api"} },
    .{ .wire_field = "verification", .kind = .carries, .targets = &.{"verification"} },
    .{ .wire_field = "aot", .kind = .carries, .targets = &.{"aot"} },
    .{ .wire_field = "faultCoverage", .kind = .carries, .targets = &.{"fault_coverage"} },
    .{ .wire_field = "rateLimiting", .kind = .carries, .targets = &.{"rate_limiting"} },
    .{ .wire_field = "properties", .kind = .carries, .targets = &.{"properties"} },
    .{ .wire_field = "declaredSpecs", .kind = .carries, .targets = &.{"declared_specs"} },
    .{ .wire_field = "specDiagnostics", .kind = .carries, .targets = &.{"spec_diagnostics"} },
    .{
        .wire_field = "sandbox",
        .kind = .carries,
        .targets = &.{ "capabilities", "capability_budget", "policy_hash", "wasm_policy_hash", "artifact_sha256" },
    },
    .{ .wire_field = "intent", .kind = .carries, .targets = &.{"intent"} },
    .{ .wire_field = "sagas", .kind = .retired_refused, .reason = retired_reason },
    .{ .wire_field = "behaviors", .kind = .carries, .targets = &.{"behaviors"} },
    .{ .wire_field = "behaviorsExhaustive", .kind = .carries, .targets = &.{"behaviors_exhaustive"} },
    .{ .wire_field = "costEnvelope", .kind = .carries, .targets = &.{"cost_envelope"} },
    .{ .wire_field = "extensions", .kind = .carries, .targets = &.{"extensions"} },
};

fn startsWith(comptime text: []const u8, comptime prefix: []const u8) bool {
    return std.mem.startsWith(u8, text, prefix);
}

fn entryFor(comptime table: []const Entry, comptime field: []const u8) ?Entry {
    for (table) |entry| {
        if (std.mem.eql(u8, entry.field, field)) return entry;
    }
    return null;
}

/// Return the first problem in the field census for `Contract`, or null.
/// `table` classifies `Contract` fields. `wire` maps the parser mirror onto them.
pub fn schemaProblem(
    comptime Contract: type,
    comptime table: []const Entry,
    comptime wire: []const WireEntry,
) ?[]const u8 {
    @setEvalBranchQuota(200_000);
    const type_name = @typeName(Contract);

    for (table, 0..) |entry, index| {
        if (!@hasField(Contract, entry.field)) return type_name ++ ": entry names no field: " ++ entry.field;
        for (table[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.field, entry.field)) return type_name ++ ": duplicate entry: " ++ entry.field;
        }
        switch (entry.wire) {
            .serialized => if (entry.wire_reason.len != 0)
                return type_name ++ ": a serialized field has a wire reason: " ++ entry.field,
            .not_serialized => if (entry.wire_reason.len == 0)
                return type_name ++ ": a not_serialized field has no reason: " ++ entry.field,
        }
        switch (entry.diff) {
            .diffed => if (entry.diff_reason.len != 0)
                return type_name ++ ": a diffed field has a diff reason: " ++ entry.field,
            .partly_diffed, .not_diffed => if (!startsWith(entry.diff_reason, "design: ") and !startsWith(entry.diff_reason, "gap: "))
                return type_name ++ ": a diff reason must start with `design: ` or `gap: `: " ++ entry.field,
        }
    }
    for (std.meta.fields(Contract)) |field| {
        if (entryFor(table, field.name) == null) return type_name ++ ": field has no entry: " ++ field.name;
    }

    for (wire, 0..) |entry, index| {
        for (wire[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.wire_field, entry.wire_field)) return "duplicate wire entry: " ++ entry.wire_field;
        }
        switch (entry.kind) {
            .carries => if (entry.targets.len == 0 or entry.reason.len != 0)
                return "a carrying wire field needs targets and no reason: " ++ entry.wire_field,
            .retired_refused => if (entry.targets.len != 0 or entry.reason.len == 0)
                return "a retired wire field needs a reason and no targets: " ++ entry.wire_field,
        }
        for (entry.targets) |target| {
            const target_entry = entryFor(table, target) orelse
                return "wire field targets a field with no entry: " ++ entry.wire_field ++ " -> " ++ target;
            if (target_entry.wire != .serialized)
                return "wire field targets a field that is not serialized: " ++ entry.wire_field ++ " -> " ++ target;
        }
    }
    for (table) |entry| {
        var targeted: usize = 0;
        for (wire) |wire_entry| {
            for (wire_entry.targets) |target| {
                if (std.mem.eql(u8, target, entry.field)) targeted += 1;
            }
        }
        switch (entry.wire) {
            .serialized => if (targeted != 1)
                return type_name ++ ": a serialized field must be filled by exactly one wire field: " ++ entry.field,
            .not_serialized => if (targeted != 0)
                return type_name ++ ": a not_serialized field is filled by a wire field: " ++ entry.field,
        }
    }
    return null;
}

/// Return the first difference between the names of `Wire` fields and `wire`, or null.
pub fn wireMirrorProblem(comptime Wire_: type, comptime wire: []const WireEntry) ?[]const u8 {
    @setEvalBranchQuota(200_000);
    for (std.meta.fields(Wire_)) |field| {
        var found = false;
        for (wire) |entry| {
            if (std.mem.eql(u8, entry.wire_field, field.name)) found = true;
        }
        if (!found) return @typeName(Wire_) ++ ": field has no wire entry: " ++ field.name;
    }
    for (wire) |entry| {
        if (!@hasField(Wire_, entry.wire_field)) return @typeName(Wire_) ++ ": wire entry names no field: " ++ entry.wire_field;
    }
    return null;
}

/// Fail the build when `Wire_` and `wire_entries` disagree. The parser calls this on `ContractWire`.
pub fn requireWireMirror(comptime Wire_: type) void {
    if (wireMirrorProblem(Wire_, &wire_entries)) |problem| @compileError(problem);
}

comptime {
    if (schemaProblem(contract_types.HandlerContract, &entries, &wire_entries)) |problem| @compileError(problem);
}

/// Names of the fields whose diff reason is a gap, in declaration order.
pub fn diffGaps() []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (entries) |entry| {
            if (startsWith(entry.diff_reason, "gap: ")) names = names ++ [_][]const u8{entry.field};
        }
        return names;
    }
}

test "the census covers every HandlerContract field exactly once" {
    try std.testing.expectEqual(std.meta.fields(contract_types.HandlerContract).len, entries.len);
    var serialized: usize = 0;
    var not_serialized: usize = 0;
    for (entries) |entry| switch (entry.wire) {
        .serialized => serialized += 1,
        .not_serialized => not_serialized += 1,
    };
    try std.testing.expectEqual(@as(usize, 36), entries.len);
    try std.testing.expectEqual(@as(usize, 28), serialized);
    try std.testing.expectEqual(@as(usize, 8), not_serialized);
}

test "the wire mirror table has one entry per ContractWire field" {
    var carries: usize = 0;
    var retired: usize = 0;
    for (wire_entries) |entry| switch (entry.kind) {
        .carries => carries += 1,
        .retired_refused => retired += 1,
    };
    try std.testing.expectEqual(@as(usize, 36), wire_entries.len);
    try std.testing.expectEqual(@as(usize, 24), carries);
    try std.testing.expectEqual(@as(usize, 12), retired);
}

test "diff gaps are listed and each has a reason" {
    const gaps = comptime diffGaps();
    try std.testing.expect(gaps.len > 0);
    inline for (gaps) |name| {
        const entry = comptime entryFor(&entries, name).?;
        try std.testing.expect(entry.diff != .diffed);
    }
}

const Probe = struct { alpha: u8, beta: u8 };

fn probeEntry(comptime field: []const u8) Entry {
    return .{ .field = field, .wire = .serialized, .diff = .diffed };
}

test "schemaProblem refuses an unclassified field, a stray entry, and a missing reason" {
    const alpha = comptime probeEntry("alpha");
    const beta = comptime probeEntry("beta");
    const both_wire = [_]WireEntry{
        .{ .wire_field = "a", .kind = .carries, .targets = &.{"alpha"} },
        .{ .wire_field = "b", .kind = .carries, .targets = &.{"beta"} },
    };
    try std.testing.expect(comptime schemaProblem(Probe, &.{ alpha, beta }, &both_wire) == null);

    // A field with no entry.
    try std.testing.expect(comptime schemaProblem(Probe, &.{alpha}, both_wire[0..1]) != null);
    // An entry that names no field.
    try std.testing.expect(comptime schemaProblem(Probe, &.{ alpha, beta, probeEntry("gamma") }, &both_wire) != null);
    // A duplicate entry.
    try std.testing.expect(comptime schemaProblem(Probe, &.{ alpha, beta, alpha }, &both_wire) != null);
    // A not_serialized field with no wire reason.
    const silent = Entry{ .field = "beta", .wire = .not_serialized, .diff = .diffed };
    try std.testing.expect(comptime schemaProblem(Probe, &.{ alpha, silent }, both_wire[0..1]) != null);
    // A not_diffed field with a reason that is neither `design:` nor `gap:`.
    const vague = Entry{ .field = "beta", .wire = .serialized, .diff = .not_diffed, .diff_reason = "because" };
    try std.testing.expect(comptime schemaProblem(Probe, &.{ alpha, vague }, &both_wire) != null);
    // A serialized field that no wire field fills.
    try std.testing.expect(comptime schemaProblem(Probe, &.{ alpha, beta }, both_wire[0..1]) != null);
    // A wire field that targets a field that is not serialized.
    const quiet = Entry{
        .field = "beta",
        .wire = .not_serialized,
        .wire_reason = "transient",
        .diff = .diffed,
    };
    try std.testing.expect(comptime schemaProblem(Probe, &.{ alpha, quiet }, &both_wire) != null);
    // A retired wire field with a target.
    const bad_retired = [_]WireEntry{
        both_wire[0],
        both_wire[1],
        .{ .wire_field = "c", .kind = .retired_refused, .targets = &.{"alpha"}, .reason = "retired" },
    };
    try std.testing.expect(comptime schemaProblem(Probe, &.{ alpha, beta }, &bad_retired) != null);
}

test "wireMirrorProblem refuses an unmapped wire field and a stray entry" {
    const Mirror = struct { a: u8, b: u8 };
    const full = [_]WireEntry{
        .{ .wire_field = "a", .kind = .carries, .targets = &.{"alpha"} },
        .{ .wire_field = "b", .kind = .retired_refused, .reason = "retired" },
    };
    try std.testing.expect(comptime wireMirrorProblem(Mirror, &full) == null);
    try std.testing.expect(comptime wireMirrorProblem(Mirror, full[0..1]) != null);
    const stray = [_]WireEntry{ full[0], full[1], .{ .wire_field = "c", .kind = .retired_refused, .reason = "retired" } };
    try std.testing.expect(comptime wireMirrorProblem(Mirror, &stray) != null);
}

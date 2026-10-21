//! Precision expectations for the flow checker (redesign plan R16).
//!
//! R16 rule: a representative handler must prove, under any flow checker, every
//! flow property that the old checker proved on the baseline. The owner
//! corrected two false weather-egress promises on 2026-10-20: sending a
//! validated city in an external URL cannot prove pii_contained or
//! injection_safe under the accepted strict sink policy. This is the only
//! approved change to the frozen expectations; input_validated stays required.
//! A property that
//! the old checker left unproven gets no expectation, because a more precise
//! checker may prove more. The new interpreter (plan P9) may not replace the old
//! checker until it meets every expectation here with no exemption. Each
//! difference from the old checker needs a written disposition first.
//!
//! The old checker must meet the expectations too, so this is a running test
//! from the first commit. `old_checker_misses` is the only exemption table. It
//! is empty today. Each row names a handler, a property, and a reason. A test
//! holds the table equal to the observed misses, so the table can only shrink.
//! The P9 gate does not read the table.
//!
//! The corpus has three groups:
//!   * `examples/` handlers, read in place by repository-relative path.
//!   * `packages/tools/tests/fixtures/flow_precision/corpus/<case>/`, a copy of
//!     each committed DeepSeek codegen handler. A re-record of the codegen
//!     corpus changes the originals, so this copy stays fixed. The `SOURCE`
//!     file in each case names the generation hash it came from.
//!   * `packages/tools/tests/fixtures/flow_precision/auth/`, four handwritten
//!     authenticated handlers. `auth_branch_selected_message.ts` chooses its
//!     response by comparing a secret, so it pins the explicit-flow policy
//!     (plan D9 Option A).
//!
//! Excluded handlers, because they reach no flow verdict:
//!   * `examples/handler/feature-probes.ts` is a probe file for unsupported
//!     syntax. The parser refuses it, so the flow stage does not run.
//!   * `examples/handler/utils.ts` is a helper module, not a handler. It has no
//!     handler function to analyze.
//!
//! `examples/fetch/webhook.ts` is a listed entry with an empty expectation. It
//! stays in the manifest so that a later proof shows in review.
//!
//! Paths are repository-relative.
//! The tests work when they run from the repository root, which is how
//! `zig build` runs them. Each handler runs through the production typed
//! pipeline, `precompile.runCheckOnlyFromSourceWithOptions`, with its real path
//! so that relative imports resolve. The reader does not use
//! `flow_census_gate.classify`: that function reports no verdict for a false
//! property without a claim failure, and for any non-flow error, and these
//! handlers carry no `Proof<...>` claims.

const std = @import("std");
const zts = @import("zts");
const precompile = @import("precompile.zig");

const file_io = zts.file_io;

const Property = enum {
    no_secret_leakage,
    no_credential_leakage,
    input_validated,
    pii_contained,
    injection_safe,
};

const Set = std.EnumSet(Property);

const all: Set = Set.initFull();
const none: Set = Set.initEmpty();
const all_but_secret: Set = Set.initMany(&.{ .no_credential_leakage, .input_validated, .pii_contained, .injection_safe });
const all_but_secret_credential: Set = Set.initMany(&.{ .input_validated, .pii_contained, .injection_safe });
const secret_and_credential_only: Set = Set.initMany(&.{ .no_secret_leakage, .no_credential_leakage });

pub const Entry = struct {
    /// Repository-relative path. Unique.
    path: []const u8,
    /// The properties the old checker proves on the baseline.
    expect: Set,
    /// A SQL schema for a handler that registers `zttp:sql` queries.
    sql_schema_path: ?[]const u8 = null,
};

const corpus_root = "packages/tools/tests/fixtures/flow_precision/corpus/";
const auth_root = "packages/tools/tests/fixtures/flow_precision/auth/";

/// Frozen. A change needs a commit message that gives the reason.
const frozen_entry_count: usize = 48;
/// Frozen. The total number of expected property bits over all entries.
const frozen_expected_bits: usize = 214;

pub const entries = [_]Entry{
    .{ .path = "examples/autoloop/handler.ts", .expect = all_but_secret },
    .{ .path = "examples/fetch/weather-app.ts", .expect = secret_and_credential_only },
    .{ .path = "examples/fetch/weather-forecasts.ts", .expect = all },
    .{ .path = "examples/fetch/webhook.ts", .expect = none },
    .{ .path = "examples/handler/effects-capsule.ts", .expect = all },
    .{ .path = "examples/handler/handler-with-imports.ts", .expect = all },
    .{ .path = "examples/handler/handler.ts", .expect = all },
    .{ .path = "examples/handler/secret-leak.ts", .expect = all_but_secret },
    .{ .path = "examples/handler/spec-fails-idempotent.ts", .expect = all },
    .{ .path = "examples/handler/spec-guardrails.ts", .expect = all },
    .{ .path = "examples/handler/sugar.ts", .expect = all_but_secret_credential },
    .{ .path = "examples/modules/modules.ts", .expect = all },
    .{ .path = "examples/modules/modules_all.ts", .expect = all_but_secret_credential },
    .{ .path = "examples/patterns/annotate-not-assert.ts", .expect = all },
    .{ .path = "examples/patterns/boundary-types.ts", .expect = all },
    .{ .path = "examples/patterns/bytes-boundary.ts", .expect = all },
    .{ .path = "examples/patterns/derive-types.ts", .expect = all },
    .{ .path = "examples/patterns/discriminated-union-match.ts", .expect = all },
    .{ .path = "examples/patterns/infer-and-generics.ts", .expect = all },
    .{ .path = "examples/patterns/json-and-dict.ts", .expect = all },
    .{ .path = "examples/patterns/literal-types-no-enum.ts", .expect = all },
    .{ .path = "examples/patterns/nominal-brand.ts", .expect = all },
    .{ .path = "examples/patterns/recursive-json-value.ts", .expect = all },
    .{ .path = "examples/patterns/result-combinators.ts", .expect = all },
    .{ .path = "examples/patterns/unknown-and-guards.ts", .expect = all },
    .{ .path = "examples/patterns/validate-external.ts", .expect = all },
    .{ .path = "examples/routing/api-surface.ts", .expect = all },
    .{ .path = "examples/routing/guard-flow.ts", .expect = all_but_secret_credential },
    .{ .path = "examples/routing/match-handler.ts", .expect = all },
    .{ .path = "examples/routing/router.ts", .expect = all },
    .{ .path = "examples/sql/sql-crud.ts", .expect = all_but_secret_credential, .sql_schema_path = "examples/sql/schema.sql" },
    .{ .path = corpus_root ++ "cache-counter/handler.ts", .expect = all_but_secret_credential },
    .{ .path = corpus_root ++ "cache-counter-holes/handler.ts", .expect = all_but_secret_credential },
    .{ .path = corpus_root ++ "egress-options/handler.ts", .expect = all },
    .{ .path = corpus_root ++ "egress-options-holes/handler.ts", .expect = all },
    .{ .path = corpus_root ++ "health/handler.ts", .expect = all },
    .{ .path = corpus_root ++ "health-holes/handler.ts", .expect = all },
    .{ .path = corpus_root ++ "jwt-auth/handler.ts", .expect = all },
    .{ .path = corpus_root ++ "log-timestamp/handler.ts", .expect = all },
    .{ .path = corpus_root ++ "sibling-helper/handler.ts", .expect = all },
    .{ .path = corpus_root ++ "sibling-helper-holes/handler.ts", .expect = all },
    .{ .path = corpus_root ++ "sql-users/handler.ts", .expect = all_but_secret_credential, .sql_schema_path = corpus_root ++ "sql-users/schema.sql" },
    .{ .path = corpus_root ++ "validate-body/handler.ts", .expect = all },
    // Owner-approved correction, 2026-10-20: validation does not contain PII
    // or establish the URL/header injection defense. No miss-table exemption.
    .{ .path = corpus_root ++ "weather-egress/handler.ts", .expect = Set.initMany(&.{ .no_secret_leakage, .no_credential_leakage, .input_validated }) },
    .{ .path = auth_root ++ "auth_api_key.ts", .expect = all },
    .{ .path = auth_root ++ "auth_bearer_escaped_html.ts", .expect = all },
    .{ .path = auth_root ++ "auth_branch_selected_message.ts", .expect = all },
    .{ .path = auth_root ++ "auth_webhook_logged.ts", .expect = all },
};

pub const Miss = struct {
    path: []const u8,
    property: Property,
    /// Why the old checker cannot meet this expectation, in plain words.
    reason: []const u8,
};

/// Expectations the old checker does not meet. Empty today. A row here
/// exempts the old checker only. The P9 gate checks every expectation.
const old_checker_misses = [_]Miss{};

const max_source_bytes: usize = 1 << 20;

/// The properties the pipeline reports as proven for one handler.
fn observe(allocator: std.mem.Allocator, entry: Entry) !Set {
    const source = file_io.readFile(allocator, entry.path, max_source_bytes) catch |err| {
        std.debug.print("flow precision: cannot read {s}: {s}\n", .{ entry.path, @errorName(err) });
        return err;
    };
    defer allocator.free(source);

    var result = try precompile.runCheckOnlyFromSourceWithOptions(
        allocator,
        source,
        entry.path,
        .{ .json_mode = true, .sql_schema_path = entry.sql_schema_path },
    );
    defer result.deinit(allocator);

    if (!result.stages_run.contains(.flow)) {
        std.debug.print("flow precision: {s} did not run the flow stage\n", .{entry.path});
        return error.FlowStageDidNotRun;
    }
    const properties = result.properties orelse {
        std.debug.print("flow precision: {s} produced no handler properties\n", .{entry.path});
        return error.NoHandlerProperties;
    };

    var held = Set.initEmpty();
    if (properties.no_secret_leakage) held.insert(.no_secret_leakage);
    if (properties.no_credential_leakage) held.insert(.no_credential_leakage);
    if (properties.input_validated) held.insert(.input_validated);
    if (properties.pii_contained) held.insert(.pii_contained);
    if (properties.injection_safe) held.insert(.injection_safe);
    return held;
}

fn inMissTable(path: []const u8, property: Property) bool {
    for (old_checker_misses) |miss| {
        if (miss.property == property and std.mem.eql(u8, miss.path, path)) return true;
    }
    return false;
}

fn expectedBits() usize {
    var total: usize = 0;
    for (entries) |entry| total += entry.expect.count();
    return total;
}

test "the manifest has unique paths, frozen counts, and readable files" {
    const allocator = std.testing.allocator;
    for (entries, 0..) |a, i| {
        for (entries[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.path, b.path)) std.debug.print("duplicate path {s}\n", .{a.path});
            try std.testing.expect(!std.mem.eql(u8, a.path, b.path));
        }
    }
    try std.testing.expectEqual(frozen_entry_count, entries.len);
    try std.testing.expectEqual(frozen_expected_bits, expectedBits());

    var read: usize = 0;
    for (entries) |entry| {
        const source = file_io.readFile(allocator, entry.path, max_source_bytes) catch |err| {
            std.debug.print("flow precision: cannot read {s}: {s}\n", .{ entry.path, @errorName(err) });
            return err;
        };
        allocator.free(source);
        read += 1;
        if (entry.sql_schema_path) |schema| {
            const text = file_io.readFile(allocator, schema, max_source_bytes) catch |err| {
                std.debug.print("flow precision: cannot read {s}: {s}\n", .{ schema, @errorName(err) });
                return err;
            };
            allocator.free(text);
        }
    }
    try std.testing.expectEqual(entries.len, read);
}

test "every expected property holds except the old-checker misses" {
    const allocator = std.testing.allocator;
    var failures: usize = 0;
    var checked: usize = 0;
    for (entries) |entry| {
        const held = try observe(allocator, entry);
        var it = entry.expect.iterator();
        while (it.next()) |property| {
            checked += 1;
            if (held.contains(property)) continue;
            if (inMissTable(entry.path, property)) continue;
            failures += 1;
            std.debug.print("flow precision: {s} does not prove {s}\n", .{ entry.path, @tagName(property) });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expectEqual(frozen_expected_bits, checked);
}

test "the old-checker miss table equals the observed misses" {
    const allocator = std.testing.allocator;
    var observed_misses: usize = 0;
    for (entries) |entry| {
        const held = try observe(allocator, entry);
        var it = entry.expect.iterator();
        while (it.next()) |property| {
            if (held.contains(property)) continue;
            observed_misses += 1;
            if (!inMissTable(entry.path, property)) {
                std.debug.print("flow precision: miss {s} {s} has no table row\n", .{ entry.path, @tagName(property) });
                return error.MissingMissRow;
            }
        }
    }
    for (old_checker_misses) |miss| {
        try std.testing.expect(miss.reason.len > 0);
        var found = false;
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.path, miss.path) and entry.expect.contains(miss.property)) found = true;
        }
        if (!found) std.debug.print("flow precision: miss row {s} names no expectation\n", .{miss.path});
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(old_checker_misses.len, observed_misses);
}

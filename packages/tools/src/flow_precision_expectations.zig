//! Precision expectations for the flow checker.
//!
//! Rule: a representative handler must prove every frozen expectation under the
//! flow checker. A missing proof fails the test. No exemption table exists. The
//! owner corrected two false weather-egress promises on 2026-10-20: sending a
//! validated city in an external URL cannot prove pii_contained or
//! injection_safe under the accepted strict sink policy. This is the only
//! approved change to the frozen expectations; input_validated stays required.
//! A property with no expectation may prove or not, because a more precise
//! checker may prove more.
//!
//! Owner decision D3(a), 2026-10-21 (recorded as D-014): every literal `env()`
//! name is secret unless the project policy lists it in `env.public`. An entry
//! whose handler returns a non-secret env value therefore carries a
//! `policy_source` that lists the name. No expectation is lowered: the policy
//! restores the verdict the name heuristic gave before.
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
const false_proofs = @import("flow_false_proofs.zig");

const file_io = zts.file_io;

const Property = enum {
    no_secret_leakage,
    no_credential_leakage,
    input_validated,
    pii_contained,
    injection_safe,
};

const Set = std.EnumSet(Property);

// The precision table records the five data-flow labels. A new `HandlerProperties` field is
// recorded above or named here.
const unrecorded_properties = zts.HandlerProperties.exclusions(
    &.{ "pure", "read_only", "stateless", "retry_safe", "deterministic", "has_egress", "idempotent", "max_io_depth", "state_isolated", "fault_covered", "result_safe", "optional_safe", "post_only", "canonical", "cost_bounded" },
    "the precision table records the five data-flow properties only",
);

comptime {
    if (zts.HandlerProperties.coverageProblem(Property, &unrecorded_properties)) |problem| @compileError(problem);
}

const all: Set = Set.full;
const none: Set = Set.empty;
const all_but_secret: Set = Set.initMany(&.{ .no_credential_leakage, .input_validated, .pii_contained, .injection_safe });
const all_but_secret_credential: Set = Set.initMany(&.{ .input_validated, .pii_contained, .injection_safe });
const secret_and_credential_only: Set = Set.initMany(&.{ .no_secret_leakage, .no_credential_leakage });

pub const Entry = struct {
    /// Repository-relative path. Unique.
    path: []const u8,
    /// The properties the flow checker must prove for this handler.
    expect: Set,
    /// A SQL schema for a handler that registers `zttp:sql` queries.
    sql_schema_path: ?[]const u8 = null,
    /// The capability policy the handler is checked under. A handler that
    /// returns an `env(...)` value needs the policy that lists the name in
    /// `env.public` (D-014); the expectation itself is not lowered.
    policy_source: ?[]const u8 = null,
};

const corpus_root = "packages/tools/tests/fixtures/flow_precision/corpus/";
const auth_root = "packages/tools/tests/fixtures/flow_precision/auth/";

/// The policies that list the one non-secret name each handler below returns
/// (D-014). The expectations stay as frozen; the handlers gain a policy.
const modules_policy =
    \\{"env":{"allow":["APP_NAME","WEBHOOK_SECRET"],"public":["APP_NAME"]}}
;
const bytes_scope_policy =
    \\{"env":{"allow":["BYTES_SCOPE"],"public":["BYTES_SCOPE"]}}
;
const app_name_policy =
    \\{"env":{"allow":["APP_NAME"],"public":["APP_NAME"]}}
;
const sibling_policy =
    \\{"env":{"allow":["API_TOKEN","APP_NAME"],"public":["APP_NAME"]}}
;

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
    .{ .path = "examples/modules/modules.ts", .expect = all, .policy_source = modules_policy },
    .{ .path = "examples/modules-all/modules_all.ts", .expect = all_but_secret_credential },
    .{ .path = "examples/patterns/annotate-not-assert.ts", .expect = all },
    .{ .path = "examples/patterns/boundary-types.ts", .expect = all },
    .{ .path = "examples/patterns/bytes-boundary.ts", .expect = all, .policy_source = bytes_scope_policy },
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
    .{ .path = "examples/routing/router.ts", .expect = all, .policy_source = app_name_policy },
    .{ .path = "examples/sql/sql-crud.ts", .expect = all_but_secret_credential, .sql_schema_path = "examples/sql/schema.sql" },
    .{ .path = corpus_root ++ "cache-counter/handler.ts", .expect = all_but_secret_credential },
    .{ .path = corpus_root ++ "cache-counter-holes/handler.ts", .expect = all_but_secret_credential },
    .{ .path = corpus_root ++ "egress-options/handler.ts", .expect = all },
    .{ .path = corpus_root ++ "egress-options-holes/handler.ts", .expect = all },
    .{ .path = corpus_root ++ "health/handler.ts", .expect = all },
    .{ .path = corpus_root ++ "health-holes/handler.ts", .expect = all },
    .{ .path = corpus_root ++ "jwt-auth/handler.ts", .expect = all },
    .{ .path = corpus_root ++ "log-timestamp/handler.ts", .expect = all },
    .{ .path = corpus_root ++ "sibling-helper/handler.ts", .expect = all, .policy_source = sibling_policy },
    .{ .path = corpus_root ++ "sibling-helper-holes/handler.ts", .expect = all, .policy_source = sibling_policy },
    .{ .path = corpus_root ++ "sql-users/handler.ts", .expect = all_but_secret_credential, .sql_schema_path = corpus_root ++ "sql-users/schema.sql" },
    .{ .path = corpus_root ++ "validate-body/handler.ts", .expect = all },
    // Owner-approved correction, 2026-10-20: validation does not contain PII
    // or establish the URL/header injection defense.
    .{ .path = corpus_root ++ "weather-egress/handler.ts", .expect = Set.initMany(&.{ .no_secret_leakage, .no_credential_leakage, .input_validated }) },
    .{ .path = auth_root ++ "auth_api_key.ts", .expect = all },
    .{ .path = auth_root ++ "auth_bearer_escaped_html.ts", .expect = all },
    .{ .path = auth_root ++ "auth_branch_selected_message.ts", .expect = all },
    .{ .path = auth_root ++ "auth_webhook_logged.ts", .expect = all },
};

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
        .{ .json_mode = true, .sql_schema_path = entry.sql_schema_path, .policy_source = entry.policy_source },
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

    var held = Set.empty;
    if (properties.no_secret_leakage) held.insert(.no_secret_leakage);
    if (properties.no_credential_leakage) held.insert(.no_credential_leakage);
    if (properties.input_validated) held.insert(.input_validated);
    if (properties.pii_contained) held.insert(.pii_contained);
    if (properties.injection_safe) held.insert(.injection_safe);
    return held;
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

test "every expected property holds" {
    const allocator = std.testing.allocator;
    var failures: usize = 0;
    var checked: usize = 0;
    for (entries) |entry| {
        const held = try observe(allocator, entry);
        var it = entry.expect.iterator();
        while (it.next()) |property| {
            checked += 1;
            if (held.contains(property)) continue;
            failures += 1;
            std.debug.print("flow precision: {s} does not prove {s}\n", .{ entry.path, @tagName(property) });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expectEqual(frozen_expected_bits, checked);
}

/// Cases the whole frozen corpus holds: the precision manifest, the permanent
/// unsafe fixtures, and the clean contrasts. The count keeps the floors below
/// from passing over an emptied corpus.
const frozen_corpus_cases: usize = 90;

const CorpusTally = struct {
    cases: usize = 0,
    unresolved: usize = 0,
    source_errors: usize = 0,
};

/// Run one case through the production check path. A read failure, a refused
/// run, a missing flow stage, or missing properties counts as a source error.
fn tallyCase(allocator: std.mem.Allocator, tally: *CorpusTally, name: []const u8, source: []const u8, path: []const u8, schema: ?[]const u8, policy: ?[]const u8) void {
    tally.cases += 1;
    var result = precompile.runCheckOnlyFromSourceWithOptions(allocator, source, path, .{ .json_mode = true, .sql_schema_path = schema, .policy_source = policy }) catch |err| {
        std.debug.print("flow corpus: {s} failed to check: {s}\n", .{ name, @errorName(err) });
        tally.source_errors += 1;
        return;
    };
    defer result.deinit(allocator);
    if (!result.stages_run.contains(.flow) or result.properties == null) {
        std.debug.print("flow corpus: {s} reached no flow verdict\n", .{name});
        tally.source_errors += 1;
        return;
    }
    if (result.flow_unresolved != 0) {
        std.debug.print("flow corpus: {s} left {d} construct(s) unresolved\n", .{ name, result.flow_unresolved });
        tally.unresolved += result.flow_unresolved;
    }
}

test "the frozen corpus leaves no construct unresolved and has no source error" {
    const allocator = std.testing.allocator;
    var tally: CorpusTally = .{};
    for (entries) |entry| {
        const source = file_io.readFile(allocator, entry.path, max_source_bytes) catch |err| {
            std.debug.print("flow corpus: cannot read {s}: {s}\n", .{ entry.path, @errorName(err) });
            tally.cases += 1;
            tally.source_errors += 1;
            continue;
        };
        defer allocator.free(source);
        tallyCase(allocator, &tally, entry.path, source, entry.path, entry.sql_schema_path, entry.policy_source);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ false_proofs.fixtures, false_proofs.contrasts }) |group| {
        for (group) |fixture| {
            var schema_path: ?[:0]u8 = null;
            defer if (schema_path) |path| allocator.free(path);
            if (fixture.sql_schema) |schema| {
                try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "schema.sql", .data = schema });
                schema_path = try tmp.dir.realPathFileAlloc(std.testing.io, "schema.sql", allocator);
            }
            tallyCase(allocator, &tally, fixture.name, fixture.source, "flow-false-proof.ts", schema_path, fixture.policy_source);
        }
    }
    try std.testing.expectEqual(frozen_corpus_cases, tally.cases);
    try std.testing.expectEqual(frozen_entry_count + false_proofs.fixtures.len + false_proofs.contrasts.len, tally.cases);
    try std.testing.expectEqual(@as(usize, 0), tally.source_errors);
    try std.testing.expectEqual(@as(usize, 0), tally.unresolved);
}

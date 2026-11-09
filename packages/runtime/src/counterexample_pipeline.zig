//! Counterexample pipeline.
//!
//! Builds a `CounterexamplePreview` from the contract provenance and the diff
//! the live-reload loop already has. The preview borrows every string from
//! the contract, `property_metas`, and the static suggestion catalog; it owns
//! nothing and must not outlive any of those.

const std = @import("std");
const zts = @import("zts");
const review = @import("proofs/review.zig");
const PropertyProvenance = zts.handler_contract.PropertyProvenance;

pub const Preview = review.CounterexamplePreview;

/// The suggestion for a cause. The preview holds static strings only, so an export cause gets
/// the static export text and not the text that names the export.
fn suggestionFor(name: []const u8, snippet: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, name, "deterministic")) return zts.spec_discharge.suggestionFor(name);
    return switch (zts.handler_contract.deterministicCauseKind(snippet)) {
        .branch => zts.spec_discharge.branch_suggestion,
        .builtin_read => zts.spec_discharge.suggestionFor(name),
        .module_export => zts.spec_discharge.export_suggestion,
    };
}

/// Return a preview for the first demoted property whose cause the verifier
/// has recorded on `provenance`. Returns null when there are no demotions
/// or none of them carry a cause yet.
pub fn buildFromDelta(
    handler_path: []const u8,
    provenance: *const PropertyProvenance,
    delta: *const review.ReviewDelta,
) ?Preview {
    if (delta.demoted_properties.len == 0) return null;

    for (delta.demoted_properties) |demoted| {
        if (provenance.causeFor(demoted.name)) |c| {
            return .{
                .field = demoted.name,
                .label = demoted.label,
                .line = c.line,
                .column = c.column,
                .snippet = c.snippet,
                .handler_path = handler_path,
                .suggestion = suggestionFor(demoted.name, c.snippet),
            };
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "buildFromDelta returns null when no properties demoted" {
    const provenance = PropertyProvenance{
        .deterministic = .{ .line = 14, .column = 9, .snippet = "Date.now()" },
    };
    const delta = review.ReviewDelta{};
    try testing.expect(buildFromDelta("src/handler.ts", &provenance, &delta) == null);
}

test "buildFromDelta returns null when demoted property has no recorded cause" {
    const provenance = PropertyProvenance{};
    const demoted = [_]review.PropertyChange{.{
        .name = "deterministic",
        .label = "deterministic",
        .old_value = true,
        .new_value = false,
    }};
    const delta = review.ReviewDelta{ .demoted_properties = demoted[0..] };
    try testing.expect(buildFromDelta("src/handler.ts", &provenance, &delta) == null);
}

test "buildFromDelta returns a populated preview when cause is recorded" {
    const provenance = PropertyProvenance{
        .deterministic = .{ .line = 14, .column = 9, .snippet = "Date.now()" },
    };
    const demoted = [_]review.PropertyChange{.{
        .name = "deterministic",
        .label = "deterministic",
        .old_value = true,
        .new_value = false,
    }};
    const delta = review.ReviewDelta{ .demoted_properties = demoted[0..] };

    const preview = buildFromDelta("src/handler.ts", &provenance, &delta).?;
    try testing.expectEqualStrings("deterministic", preview.field);
    try testing.expectEqualStrings("deterministic", preview.label);
    try testing.expectEqual(@as(u32, 14), preview.line);
    try testing.expectEqualStrings("Date.now()", preview.snippet);
    try testing.expectEqualStrings("src/handler.ts", preview.handler_path);
    try testing.expect(preview.suggestion != null);
    try testing.expect(std.mem.indexOf(u8, preview.suggestion.?, "Date.now()") != null);
}

test "buildFromDelta gives the branch suggestion for a branch cause of deterministic" {
    const provenance = PropertyProvenance{
        .deterministic = .{
            .line = 3,
            .column = 3,
            .snippet = "a branch on a value that varies between requests",
        },
    };
    const demoted = [_]review.PropertyChange{.{
        .name = "deterministic",
        .label = "deterministic",
        .old_value = true,
        .new_value = false,
    }};
    const delta = review.ReviewDelta{ .demoted_properties = demoted[0..] };

    const preview = buildFromDelta("src/handler.ts", &provenance, &delta).?;
    try testing.expectEqualStrings("a branch on a value that varies between requests", preview.snippet);
    try testing.expectEqualStrings(
        "the response is reached through a branch on a value that varies between requests, such as a clock, random, network, rate-limit, cache, or token read: declare a capsule without `deterministic` and `idempotent`, or move the varying read so that no branch on it precedes the return of the response.",
        preview.suggestion.?,
    );
}

test "buildFromDelta gives a static export suggestion for an export cause of deterministic" {
    const provenance = PropertyProvenance{
        .deterministic = .{
            .line = 4,
            .column = 13,
            .snippet = "rateCheck",
        },
    };
    const demoted = [_]review.PropertyChange{.{
        .name = "deterministic",
        .label = "deterministic",
        .old_value = true,
        .new_value = false,
    }};
    const delta = review.ReviewDelta{ .demoted_properties = demoted[0..] };

    const preview = buildFromDelta("src/handler.ts", &provenance, &delta).?;
    try testing.expectEqualStrings("rateCheck", preview.snippet);
    try testing.expectEqualStrings(
        "remove the varying read from the response path, or declare a capsule without `deterministic` and `idempotent`.",
        preview.suggestion.?,
    );
}

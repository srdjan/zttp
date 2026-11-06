//! Shared projection from `zts.HandlerContract.spec_diagnostics` into the
//! `review.SpecState` shape used by the proof HUD, the
//! deploy review card, and the proof ledger. Consumed by both
//! `live_reload.zig` (per-recompile) and `deploy.zig` (per-deploy review).

const std = @import("std");
const zts = @import("zts");
const review = @import("review.zig");

/// Build a transient SpecState for a single declared spec name. Strings
/// borrow from the contract (zero-allocation); `ReviewFacts.fromProvenFacts`
/// dupes them when persisting.
pub fn specStateFor(contract: *const zts.HandlerContract, name: []const u8) review.SpecState {
    for (contract.spec_diagnostics.items) |d| {
        // Author-declared Specs carry one diagnostic per spec_name. The
        // implicit-default profile collapses its undischarged properties into a
        // single not_discharged whose spec_name is the joined "a, b, c" set, so
        // match `name` against any token in that set too - otherwise the HUD,
        // deploy card, and ledger would all report the collapsed
        // properties as discharged.
        const matches = std.mem.eql(u8, d.spec_name, name) or
            (d.implicit_default and d.kind == .not_discharged and joinedSetContains(d.spec_name, name));
        if (!matches) continue;
        return .{
            .name = name,
            .discharged = false,
            .diagnostic_code = d.kind.code(),
            .diagnostic_message = specDiagnosticMessage(d),
            // The review facts carry no file. A line and a column in another
            // file would read as a place in the handler, so a cause with a
            // file gives none; the suggestion names the file and the line.
            .source_line = if (d.cause) |c| (if (c.file == null) c.line else null) else null,
            .source_column = if (d.cause) |c| (if (c.file == null) c.column else null) else null,
            .source_snippet = if (d.cause) |c| (if (c.file == null) c.snippet else null) else null,
        };
    }
    return .{ .name = name, .discharged = true };
}

/// True if `name` is one of the `", "`-joined tokens in `joined` (the
/// collapsed implicit-default spec_name, e.g. "fault_covered, pure").
fn joinedSetContains(joined: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeSequence(u8, joined, ", ");
    while (it.next()) |token| {
        if (std.mem.eql(u8, token, name)) return true;
    }
    return false;
}

test "joinedSetContains matches a token in the collapsed spec_name set" {
    try std.testing.expect(joinedSetContains("fault_covered, idempotent, pure", "idempotent"));
    try std.testing.expect(joinedSetContains("fault_covered, idempotent, pure", "fault_covered"));
    try std.testing.expect(joinedSetContains("fault_covered, idempotent, pure", "pure"));
    try std.testing.expect(!joinedSetContains("fault_covered, idempotent, pure", "purely"));
    try std.testing.expect(!joinedSetContains("fault_covered, idempotent, pure", "retry_safe"));
    try std.testing.expect(joinedSetContains("pure", "pure"));
}

fn specDiagnosticMessage(d: zts.SpecDiagnostic) []const u8 {
    return switch (d.kind) {
        .not_discharged => d.suggestion orelse "property not discharged",
        .incompatible_with_import => d.incompatible_module orelse "spec contradicts a virtual-module import",
        .unknown_name => "spec name is not in the v1 set",
        .missing_capsule => d.suggestion orelse "helper has no Proof<...> capsule for a demanded property",
        .effect_undeclared => d.suggestion orelse "capability reached outside the declared Effects<...> ceiling",
        .effect_unknown_capability => d.suggestion orelse "Effects<...> names an unknown capability",
        .effect_over_declared => d.suggestion orelse "declared capability is never reached",
        .budget_exceeded => d.suggestion orelse "capability reached outside the handler's Effects<...> budget",
        .helper_budget_exceeded => d.suggestion orelse "helper reaches a capability outside the handler's budget",
        .missing_proof_capsule_export => d.suggestion orelse "exported helper has no Proof<...> capsule",
        .effect_ceiling_not_literal => d.suggestion orelse "Effects<...> is not a closed union of string literals, so no ceiling was read",
        .effect_row_lower_bound => d.suggestion orelse "effect row is a lower bound; a call through an unresolvable value cannot discharge a ceiling",
        .schema_not_compilable => d.suggestion orelse "a validation call names a schema zttp:validate cannot compile",
    };
}

fn contractWithReadOnlyCause(allocator: std.mem.Allocator, file: ?[]const u8) !zts.HandlerContract {
    var contract = zts.handler_contract.emptyContract(try allocator.dupe(u8, "handler.ts"));
    errdefer contract.deinit(allocator);
    const spec_name = try allocator.dupe(u8, "read_only");
    errdefer allocator.free(spec_name);
    const suggestion = try allocator.dupe(u8, "remove that write");
    errdefer allocator.free(suggestion);
    const owned_file = if (file) |f| try allocator.dupe(u8, f) else null;
    errdefer if (owned_file) |f| allocator.free(f);
    try contract.spec_diagnostics.append(allocator, .{
        .kind = .not_discharged,
        .spec_name = spec_name,
        .suggestion = suggestion,
        .cause = .{ .line = 4, .column = 12, .snippet = zts.handler_contract.state_write_snippet, .file = owned_file },
    });
    return contract;
}

test "specStateFor gives no source line, column, or snippet for a cause in another file" {
    const allocator = std.testing.allocator;
    var contract = try contractWithReadOnlyCause(allocator, "dep.ts");
    defer contract.deinit(allocator);

    const state = specStateFor(&contract, "read_only");

    try std.testing.expectEqualStrings("remove that write", state.diagnostic_message orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(?u32, null), state.source_line);
    try std.testing.expectEqual(@as(?u32, null), state.source_column);
    try std.testing.expect(state.source_snippet == null);
}

test "specStateFor gives the source line, column, and snippet for a cause in the site file" {
    const allocator = std.testing.allocator;
    var contract = try contractWithReadOnlyCause(allocator, null);
    defer contract.deinit(allocator);

    const state = specStateFor(&contract, "read_only");

    try std.testing.expectEqual(@as(?u32, 4), state.source_line);
    try std.testing.expectEqual(@as(?u32, 12), state.source_column);
    try std.testing.expectEqualStrings("a write to module state", state.source_snippet orelse return error.TestUnexpectedResult);
}

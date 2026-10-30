//! Upgrade Verifier
//!
//! Synthesizes surface diff, behavioral diff, and property regression analysis
//! into a unified upgrade verdict. This is the top-level analysis layer
//! that answers: "is this handler upgrade safe?"
//!
//! The verdict goes beyond the existing 3-value Classification (equivalent/
//! additive/breaking) by incorporating behavioral path comparison and property
//! regressions with severity.
//!
//! Called by live_reload.zig in the runtime package.

const std = @import("std");
const zts = @import("zts");
const handler_contract = zts.handler_contract;
const contract_diff = zts.contract_diff;
const HandlerContract = zts.HandlerContract;
const ContractDiff = contract_diff.ContractDiff;
const BehaviorDiff = contract_diff.BehaviorDiff;
const Classification = contract_diff.Classification;
const PropertiesChange = contract_diff.PropertiesChange;

// -------------------------------------------------------------------------
// Verdict
// -------------------------------------------------------------------------

pub const UpgradeVerdict = enum {
    /// Contract identical, properties preserved, no property regressions.
    safe,
    /// New capabilities added, existing preserved, no regressions.
    safe_with_additions,
    /// Routes/capabilities removed, paths changed, or critical property lost.
    breaking,
    /// Structurally OK but property regressions detected.
    needs_review,

    pub fn toString(self: UpgradeVerdict) []const u8 {
        return switch (self) {
            .safe => "SAFE",
            .safe_with_additions => "SAFE_WITH_ADDITIONS",
            .breaking => "BREAKING",
            .needs_review => "NEEDS_REVIEW",
        };
    }

    /// Lowercase form, for the surfaces that render the verdict as a machine
    /// token rather than a headline: the deploy card, `proofs export` markdown
    /// and HTML, and CSS class names. `toString` stays
    /// UPPERCASE for the surfaces that already print it that way.
    pub fn slug(self: UpgradeVerdict) []const u8 {
        return @tagName(self);
    }
};

// -------------------------------------------------------------------------
// Property regression
// -------------------------------------------------------------------------

/// The severity enum and the loss table live in `contract_diff`, so the
/// pull-request gate and this verifier classify a lost property identically.
pub const Severity = contract_diff.Severity;

pub const PropertyRegression = struct {
    field: []const u8,
    old_value: bool,
    new_value: bool,
    severity: Severity,
};

/// Classify a property change by severity. Gains are always informational;
/// a loss is classified by `contract_diff.propertyLossSeverity`.
fn propertySeverity(field: []const u8, gained: bool) Severity {
    if (gained) return .info;
    return contract_diff.propertyLossSeverity(field) orelse .critical;
}

// -------------------------------------------------------------------------
// Upgrade manifest
// -------------------------------------------------------------------------

pub const SurfaceSummary = struct {
    routes_added: u32 = 0,
    routes_removed: u32 = 0,
    routes_unchanged: u32 = 0,
    capabilities_widened: bool = false,
    capabilities_narrowed: bool = false,
};

pub const UpgradeManifest = struct {
    verdict: UpgradeVerdict,
    justification: []const u8, // owned
    classification: Classification,
    surface: SurfaceSummary,
    behavioral: ?BehavioralSummary,
    property_regressions: std.ArrayList(PropertyRegression),
    property_gains: std.ArrayList(PropertyRegression),

    pub const BehavioralSummary = struct {
        preserved: u32,
        response_changed: u32,
        removed: u32,
        added: u32,
    };

    pub fn deinit(self: *UpgradeManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.justification);
        self.property_regressions.deinit(allocator);
        self.property_gains.deinit(allocator);
    }
};

// -------------------------------------------------------------------------
// Analysis
// -------------------------------------------------------------------------

pub fn analyzeUpgrade(
    allocator: std.mem.Allocator,
    diff: *const ContractDiff,
    classification: Classification,
) !UpgradeManifest {
    // Surface summary
    var surface = SurfaceSummary{};
    for (diff.routes.items) |r| {
        switch (r.status) {
            .added => surface.routes_added += 1,
            .removed => surface.routes_removed += 1,
            .unchanged => surface.routes_unchanged += 1,
        }
    }
    surface.capabilities_widened = diff.capabilitiesWidened();
    surface.capabilities_narrowed = diff.capabilitiesNarrowed();

    // Property regressions and gains
    var regressions: std.ArrayList(PropertyRegression) = .empty;
    errdefer regressions.deinit(allocator);
    var gains: std.ArrayList(PropertyRegression) = .empty;
    errdefer gains.deinit(allocator);

    for (diff.effect_changes.items) |change| {
        const gained = change.new_value and !change.old_value;
        const entry = PropertyRegression{
            .field = change.field,
            .old_value = change.old_value,
            .new_value = change.new_value,
            .severity = propertySeverity(change.field, gained),
        };
        if (gained) {
            try gains.append(allocator, entry);
        } else {
            try regressions.append(allocator, entry);
        }
    }

    // Behavioral summary
    var behavioral: ?UpgradeManifest.BehavioralSummary = null;
    if (diff.behavior_diff) |bd| {
        behavioral = .{
            .preserved = bd.preserved,
            .response_changed = bd.response_changed,
            .removed = bd.removed,
            .added = bd.added,
        };
    }

    // Synthesize verdict
    const verdict = synthesizeVerdict(classification, &regressions, diff.behavior_diff);

    // Generate justification
    const justification = try generateJustification(allocator, verdict, &surface, behavioral, &regressions, &gains);

    return .{
        .verdict = verdict,
        .justification = justification,
        .classification = classification,
        .surface = surface,
        .behavioral = behavioral,
        .property_regressions = regressions,
        .property_gains = gains,
    };
}

fn synthesizeVerdict(
    classification: Classification,
    regressions: *const std.ArrayList(PropertyRegression),
    behavior_diff: ?BehaviorDiff,
) UpgradeVerdict {
    // Structural breaking is always breaking
    if (classification == .breaking) return .breaking;

    // Behavioral breaking (removed paths or changed responses)
    if (behavior_diff) |bd| {
        if (bd.hasBreaking()) return .breaking;
    }

    // Critical property regressions are breaking
    for (regressions.items) |r| {
        if (r.severity == .critical) return .breaking;
    }

    // Warning property regressions need review
    for (regressions.items) |r| {
        if (r.severity == .warning) return .needs_review;
    }

    // Additive changes
    if (classification == .additive) return .safe_with_additions;
    if (behavior_diff) |bd| {
        if (bd.added > 0) return .safe_with_additions;
    }

    return .safe;
}

fn generateJustification(
    allocator: std.mem.Allocator,
    verdict: UpgradeVerdict,
    surface: *const SurfaceSummary,
    behavioral: ?UpgradeManifest.BehavioralSummary,
    regressions: *const std.ArrayList(PropertyRegression),
    gains: *const std.ArrayList(PropertyRegression),
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const writer = &aw.writer;

    switch (verdict) {
        .safe => try writer.writeAll("Safe to deploy."),
        .safe_with_additions => try writer.writeAll("Safe to deploy with additions."),
        .breaking => try writer.writeAll("Breaking change detected."),
        .needs_review => try writer.writeAll("Requires review."),
    }

    if (surface.routes_added > 0) {
        try writer.print(" {d} route(s) added.", .{surface.routes_added});
    }
    if (surface.routes_removed > 0) {
        try writer.print(" {d} route(s) removed.", .{surface.routes_removed});
    }

    if (behavioral) |b| {
        if (b.preserved > 0) {
            try writer.print(" {d} path(s) preserved.", .{b.preserved});
        }
        if (b.response_changed > 0) {
            try writer.print(" {d} path(s) changed response.", .{b.response_changed});
        }
        if (b.removed > 0) {
            try writer.print(" {d} path(s) removed.", .{b.removed});
        }
        if (b.added > 0) {
            try writer.print(" {d} new path(s).", .{b.added});
        }
    }

    for (regressions.items) |r| {
        try writer.print(" Lost {s} ({s}).", .{ r.field, r.severity.toString() });
    }

    for (gains.items) |g| {
        try writer.print(" Gained {s}.", .{g.field});
    }

    buf = aw.toArrayList();
    return try buf.toOwnedSlice(allocator);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn testProperties(value: bool) handler_contract.HandlerProperties {
    var properties: handler_contract.HandlerProperties = .{
        .pure = value,
        .read_only = value,
        .stateless = value,
        .retry_safe = value,
        .deterministic = value,
        .has_egress = false,
    };
    inline for (@typeInfo(handler_contract.HandlerProperties).@"struct".field_names) |field| {
        if (@FieldType(handler_contract.HandlerProperties, field) == bool and handler_contract.HandlerProperties.isMonotonicProvenSpecName(field)) {
            @field(properties, field) = value;
        }
    }
    return properties;
}

fn expectIntegratedPropertyLoss(
    comptime field_name: []const u8,
    expected_severity: Severity,
    expected_verdict: UpgradeVerdict,
) !void {
    const allocator = std.testing.allocator;
    var old = handler_contract.emptyContract(try allocator.dupe(u8, "old.ts"));
    defer old.deinit(allocator);
    var new = handler_contract.emptyContract(try allocator.dupe(u8, "new.ts"));
    defer new.deinit(allocator);
    old.properties = testProperties(true);
    new.properties = testProperties(true);
    @field(new.properties.?, field_name) = false;

    var diff = try contract_diff.diffContracts(allocator, &old, &new);
    defer diff.deinit(allocator);
    var manifest = try analyzeUpgrade(allocator, &diff, diff.classify());
    defer manifest.deinit(allocator);

    try std.testing.expectEqual(expected_verdict, manifest.verdict);
    try std.testing.expectEqual(@as(usize, 1), manifest.property_regressions.items.len);
    const regression = manifest.property_regressions.items[0];
    try std.testing.expectEqualStrings(field_name, regression.field);
    try std.testing.expectEqual(expected_severity, regression.severity);
}

test "integrated critical property loss is breaking" {
    try expectIntegratedPropertyLoss("no_secret_leakage", .critical, .breaking);
}

test "integrated warning property loss needs review" {
    try expectIntegratedPropertyLoss("input_validated", .warning, .needs_review);
}

test "integrated informational property loss remains visible and safe" {
    try expectIntegratedPropertyLoss("pure", .info, .safe);
}

test "integrated property gain remains informational and safe" {
    const allocator = std.testing.allocator;
    var old = handler_contract.emptyContract(try allocator.dupe(u8, "old.ts"));
    defer old.deinit(allocator);
    var new = handler_contract.emptyContract(try allocator.dupe(u8, "new.ts"));
    defer new.deinit(allocator);
    old.properties = testProperties(true);
    new.properties = testProperties(true);
    old.properties.?.retry_safe = false;

    var diff = try contract_diff.diffContracts(allocator, &old, &new);
    defer diff.deinit(allocator);
    var manifest = try analyzeUpgrade(allocator, &diff, diff.classify());
    defer manifest.deinit(allocator);

    try std.testing.expectEqual(UpgradeVerdict.safe, manifest.verdict);
    try std.testing.expectEqual(@as(usize, 0), manifest.property_regressions.items.len);
    try std.testing.expectEqual(@as(usize, 1), manifest.property_gains.items.len);
    const gain = manifest.property_gains.items[0];
    try std.testing.expectEqualStrings("retry_safe", gain.field);
    try std.testing.expectEqual(Severity.info, gain.severity);
}

test "safe verdict for identical contracts" {
    const empty: std.ArrayList(PropertyRegression) = .empty;
    const verdict = synthesizeVerdict(.equivalent, &empty, null, null);
    try std.testing.expectEqual(UpgradeVerdict.safe, verdict);
}

test "safe_with_additions for additive classification" {
    const empty: std.ArrayList(PropertyRegression) = .empty;
    const verdict = synthesizeVerdict(.additive, &empty, null, null);
    try std.testing.expectEqual(UpgradeVerdict.safe_with_additions, verdict);
}

test "breaking for structural breaking" {
    const empty: std.ArrayList(PropertyRegression) = .empty;
    const verdict = synthesizeVerdict(.breaking, &empty, null, null);
    try std.testing.expectEqual(UpgradeVerdict.breaking, verdict);
}

test "breaking for behavioral removal" {
    const bd = BehaviorDiff{ .preserved = 2, .removed = 1 };
    const empty: std.ArrayList(PropertyRegression) = .empty;
    const verdict = synthesizeVerdict(.equivalent, &empty, bd, null);
    try std.testing.expectEqual(UpgradeVerdict.breaking, verdict);
}

test "breaking for behavioral response change" {
    const bd = BehaviorDiff{ .preserved = 2, .response_changed = 1 };
    const empty: std.ArrayList(PropertyRegression) = .empty;
    const verdict = synthesizeVerdict(.equivalent, &empty, bd, null);
    try std.testing.expectEqual(UpgradeVerdict.breaking, verdict);
}

test "breaking for critical property regression" {
    const regressions = [_]PropertyRegression{
        .{ .field = "retry_safe", .old_value = true, .new_value = false, .severity = .critical },
    };
    const list = std.ArrayList(PropertyRegression){ .items = @constCast(&regressions), .capacity = regressions.len };
    const verdict = synthesizeVerdict(.equivalent, &list, null, null);
    try std.testing.expectEqual(UpgradeVerdict.breaking, verdict);
}

test "needs_review for warning property regression" {
    const regressions = [_]PropertyRegression{
        .{ .field = "deterministic", .old_value = true, .new_value = false, .severity = .warning },
    };
    const list = std.ArrayList(PropertyRegression){ .items = @constCast(&regressions), .capacity = regressions.len };
    const verdict = synthesizeVerdict(.equivalent, &list, null, null);
    try std.testing.expectEqual(UpgradeVerdict.needs_review, verdict);
}

test "safe_with_additions for new behavioral paths" {
    const bd = BehaviorDiff{ .preserved = 3, .added = 2 };
    const empty: std.ArrayList(PropertyRegression) = .empty;
    const verdict = synthesizeVerdict(.equivalent, &empty, bd, null);
    try std.testing.expectEqual(UpgradeVerdict.safe_with_additions, verdict);
}

test "property severity classification" {
    try std.testing.expectEqual(Severity.critical, propertySeverity("retry_safe", false));
    try std.testing.expectEqual(Severity.critical, propertySeverity("injection_safe", false));
    try std.testing.expectEqual(Severity.critical, propertySeverity("result_safe", false));
    try std.testing.expectEqual(Severity.critical, propertySeverity("optional_safe", false));
    try std.testing.expectEqual(Severity.warning, propertySeverity("deterministic", false));
    try std.testing.expectEqual(Severity.info, propertySeverity("pure", false));
    // Gains are always info regardless of field
    try std.testing.expectEqual(Severity.info, propertySeverity("retry_safe", true));
}

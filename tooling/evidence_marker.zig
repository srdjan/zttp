//! Extraction and validation for release evidence markers.
//!
//! The producer writes one JSON object inside a larger test log. This module
//! finds exactly one marker line and validates the complete publication schema.

const std = @import("std");

const case_count: i64 = 13;
const intent_count: i64 = 13;

pub const Kind = enum {
    convergence,
    coverage,

    pub fn parse(value: []const u8) !Kind {
        if (std.mem.eql(u8, value, "convergence")) return .convergence;
        if (std.mem.eql(u8, value, "coverage")) return .coverage;
        return error.UnknownEvidenceKind;
    }
};

pub const Failure = error{
    UnknownEvidenceKind,
    MissingOrDuplicateMarker,
    MalformedJson,
    MarkerIsNotObject,
    InvalidFields,
    InvalidCommonEvidence,
    InvalidConvergenceEvidence,
    InvalidCoverageEvidence,
};

const common_fields = [_][]const u8{
    "runId",
    "complete",
    "publishable",
    "publicationMode",
    "expectedCases",
    "completedCases",
    "corpusCases",
    "provider",
    "model",
    "modelRevision",
    "providerRuntime",
    "requestPolicy",
    "providerToolCount",
    "providerToolBytes",
    "corpusVersion",
    "headlineInputHash",
    "intentSuiteHash",
    "securityProbeHash",
    "thresholdHash",
    "manifestHash",
    "resultRunHash",
    "promptPersonaHash",
    "providerNeutralCatalogHash",
    "providerSerializedCatalogHash",
    "schemaHash",
    "metaHash",
    "grammarHash",
    "semanticsHash",
    "diagnosticHash",
    "policyHash",
    "sourceCommit",
    "sourceDirty",
};

const digest_fields = [_][]const u8{
    "corpusVersion",
    "headlineInputHash",
    "intentSuiteHash",
    "securityProbeHash",
    "thresholdHash",
    "manifestHash",
    "resultRunHash",
    "promptPersonaHash",
    "providerNeutralCatalogHash",
    "providerSerializedCatalogHash",
    "schemaHash",
    "metaHash",
    "grammarHash",
    "semanticsHash",
    "diagnosticHash",
    "policyHash",
};

const convergence_fields = [_][]const u8{
    "rawFirstDraftPassPercent",
    "rawFirstDraftPasses",
    "firstAttemptGreenPercent",
    "firstAttemptGreens",
    "finalGreenPercent",
    "finalGreens",
    "medianRoundtrips",
    "intentPassPercent",
    "intentPasses",
    "intentChecked",
    "emptyResponses",
    "timeoutFailures",
    "decodeFailures",
};

const coverage_fields = [_][]const u8{
    "rulesTotal",
    "rulesTripped",
    "tripped",
    "untripped",
    "offRegistry",
};

pub fn extract(
    allocator: std.mem.Allocator,
    log: []const u8,
    marker: []const u8,
    kind: Kind,
) Failure!std.json.Parsed(std.json.Value) {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        const marker_at = std.mem.indexOf(u8, line, marker) orelse continue;
        if (found != null) return error.MissingOrDuplicateMarker;
        found = std.mem.trim(u8, line[marker_at + marker.len ..], " \t\r");
    }
    const encoded = found orelse return error.MissingOrDuplicateMarker;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, encoded, .{}) catch
        return error.MalformedJson;
    errdefer parsed.deinit();
    try validate(parsed.value, kind);
    return parsed;
}

pub fn validate(value: std.json.Value, kind: Kind) Failure!void {
    const object = switch (value) {
        .object => |object| object,
        else => return error.MarkerIsNotObject,
    };
    try validateExactFields(object, kind);
    try validateCommon(object);
    switch (kind) {
        .convergence => try validateConvergence(object),
        .coverage => try validateCoverage(object),
    }
}

fn validateExactFields(object: std.json.ObjectMap, kind: Kind) Failure!void {
    const kind_fields: []const []const u8 = switch (kind) {
        .convergence => &convergence_fields,
        .coverage => &coverage_fields,
    };
    if (object.count() != common_fields.len + kind_fields.len) return error.InvalidFields;
    for (common_fields) |field| {
        if (!object.contains(field)) return error.InvalidFields;
    }
    for (kind_fields) |field| {
        if (!object.contains(field)) return error.InvalidFields;
    }
}

fn validateCommon(object: std.json.ObjectMap) Failure!void {
    if (!trueField(object, "complete") or
        !trueField(object, "publishable") or
        !trueField(object, "publicationMode")) return error.InvalidCommonEvidence;

    if (!nonEmptyStringField(object, "runId")) return error.InvalidCommonEvidence;
    if (integerField(object, "expectedCases") != case_count or
        integerField(object, "completedCases") != case_count or
        integerField(object, "corpusCases") != case_count) return error.InvalidCommonEvidence;
    if (!nonEmptyStringField(object, "provider") or
        !nonEmptyStringField(object, "model")) return error.InvalidCommonEvidence;

    const model_revision = object.get("modelRevision") orelse return error.InvalidCommonEvidence;
    if (model_revision != .null and !isNonEmptyString(model_revision)) return error.InvalidCommonEvidence;

    const runtime = object.get("providerRuntime") orelse return error.InvalidCommonEvidence;
    if (runtime != .null) {
        const runtime_object = switch (runtime) {
            .object => |value| value,
            else => return error.InvalidCommonEvidence,
        };
        if (runtime_object.count() != 2 or
            !nonEmptyStringField(runtime_object, "name") or
            !nonEmptyStringField(runtime_object, "revision")) return error.InvalidCommonEvidence;
    }

    const policy_value = object.get("requestPolicy") orelse return error.InvalidCommonEvidence;
    const policy = switch (policy_value) {
        .object => |value| value,
        else => return error.InvalidCommonEvidence,
    };
    if (policy.count() != 5 or
        positiveIntegerField(policy, "maxOutputTokens") == null or
        positiveIntegerField(policy, "reserveTokens") == null) return error.InvalidCommonEvidence;
    const stream = policy.get("stream") orelse return error.InvalidCommonEvidence;
    if (stream != .bool) return error.InvalidCommonEvidence;
    if (!stringFieldIsOneOf(policy, "purpose", &.{ "normal", "summarization" }) or
        !stringFieldIsOneOf(policy, "cachePolicy", &.{ "enabled", "disabled" }))
        return error.InvalidCommonEvidence;

    if (positiveIntegerField(object, "providerToolCount") == null or
        positiveIntegerField(object, "providerToolBytes") == null) return error.InvalidCommonEvidence;
    for (digest_fields) |field| {
        const value = object.get(field) orelse return error.InvalidCommonEvidence;
        if (value != .string or !isLowerHex(value.string, 64)) return error.InvalidCommonEvidence;
    }
    const corpus = object.get("corpusVersion") orelse return error.InvalidCommonEvidence;
    const headline = object.get("headlineInputHash") orelse return error.InvalidCommonEvidence;
    if (!std.mem.eql(u8, corpus.string, headline.string)) return error.InvalidCommonEvidence;

    const source_commit = object.get("sourceCommit") orelse return error.InvalidCommonEvidence;
    if (source_commit != .string or !isLowerHex(source_commit.string, 40))
        return error.InvalidCommonEvidence;
    const source_dirty = object.get("sourceDirty") orelse return error.InvalidCommonEvidence;
    if (source_dirty != .bool) return error.InvalidCommonEvidence;
}

fn validateConvergence(object: std.json.ObjectMap) Failure!void {
    for (convergence_fields) |field| {
        const value = integerField(object, field) orelse return error.InvalidConvergenceEvidence;
        if (value < 0) return error.InvalidConvergenceEvidence;
    }

    const raw = integerField(object, "rawFirstDraftPasses").?;
    const assisted = integerField(object, "firstAttemptGreens").?;
    const final = integerField(object, "finalGreens").?;
    if (!(raw <= assisted and assisted <= final and final <= case_count))
        return error.InvalidConvergenceEvidence;
    if (!percentMatches(object, "rawFirstDraftPasses", "rawFirstDraftPassPercent", case_count) or
        !percentMatches(object, "firstAttemptGreens", "firstAttemptGreenPercent", case_count) or
        !percentMatches(object, "finalGreens", "finalGreenPercent", case_count))
        return error.InvalidConvergenceEvidence;

    const checked = integerField(object, "intentChecked").?;
    const passed = integerField(object, "intentPasses").?;
    if (!(passed <= checked and checked <= case_count)) return error.InvalidConvergenceEvidence;
    const expected_intent_percent = if (checked == 0) 0 else @divTrunc(passed * 100, checked);
    if (integerField(object, "intentPassPercent").? != expected_intent_percent)
        return error.InvalidConvergenceEvidence;
    if (integerField(object, "medianRoundtrips").? <= 0 or checked != intent_count)
        return error.InvalidConvergenceEvidence;
    for ([_][]const u8{ "emptyResponses", "timeoutFailures", "decodeFailures" }) |field| {
        if (integerField(object, field).? != 0) return error.InvalidConvergenceEvidence;
    }
}

fn validateCoverage(object: std.json.ObjectMap) Failure!void {
    const total = positiveIntegerField(object, "rulesTotal") orelse return error.InvalidCoverageEvidence;
    const tripped_count = std.math.cast(usize, integerField(object, "rulesTripped") orelse return error.InvalidCoverageEvidence) orelse return error.InvalidCoverageEvidence;
    const tripped = try validatedCodeArray(object, "tripped");
    const untripped = try validatedCodeArray(object, "untripped");
    const off_registry = try validatedCodeArray(object, "offRegistry");
    if (tripped_count != tripped.len or total != tripped.len + untripped.len)
        return error.InvalidCoverageEvidence;
    if (arraysOverlap(tripped, untripped) or
        arraysOverlap(off_registry, tripped) or
        arraysOverlap(off_registry, untripped)) return error.InvalidCoverageEvidence;
}

fn validatedCodeArray(object: std.json.ObjectMap, field: []const u8) Failure![]const std.json.Value {
    const value = object.get(field) orelse return error.InvalidCoverageEvidence;
    const values = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidCoverageEvidence,
    };
    for (values, 0..) |entry, index| {
        if (!isNonEmptyString(entry)) return error.InvalidCoverageEvidence;
        for (values[0..index]) |prior| {
            if (std.mem.eql(u8, prior.string, entry.string)) return error.InvalidCoverageEvidence;
        }
    }
    return values;
}

fn arraysOverlap(a: []const std.json.Value, b: []const std.json.Value) bool {
    for (a) |left| for (b) |right| {
        if (std.mem.eql(u8, left.string, right.string)) return true;
    };
    return false;
}

fn percentMatches(
    object: std.json.ObjectMap,
    count_field: []const u8,
    percent_field: []const u8,
    denominator: i64,
) bool {
    const count = integerField(object, count_field) orelse return false;
    const percent = integerField(object, percent_field) orelse return false;
    return percent == @divTrunc(count * 100, denominator);
}

fn trueField(object: std.json.ObjectMap, field: []const u8) bool {
    const value = object.get(field) orelse return false;
    return value == .bool and value.bool;
}

fn integerField(object: std.json.ObjectMap, field: []const u8) ?i64 {
    const value = object.get(field) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn positiveIntegerField(object: std.json.ObjectMap, field: []const u8) ?usize {
    const value = integerField(object, field) orelse return null;
    if (value <= 0) return null;
    return std.math.cast(usize, value);
}

fn nonEmptyStringField(object: std.json.ObjectMap, field: []const u8) bool {
    const value = object.get(field) orelse return false;
    return isNonEmptyString(value);
}

fn isNonEmptyString(value: std.json.Value) bool {
    return value == .string and value.string.len != 0;
}

fn stringFieldIsOneOf(
    object: std.json.ObjectMap,
    field: []const u8,
    accepted: []const []const u8,
) bool {
    const value = object.get(field) orelse return false;
    if (value != .string) return false;
    for (accepted) |candidate| {
        if (std.mem.eql(u8, value.string, candidate)) return true;
    }
    return false;
}

fn isLowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn collectArgs(allocator: std.mem.Allocator, args_vector: std.process.Args) ![]const []const u8 {
    var args_iter = std.process.Args.Iterator.init(args_vector);
    defer args_iter.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |arg| allocator.free(arg);
        list.deinit(allocator);
    }
    while (args_iter.next()) |arg| try list.append(allocator, try allocator.dupe(u8, arg));
    return list.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer io_backend.deinit();
    const io = io_backend.io();
    const args = try collectArgs(allocator, init.args);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }
    if (args.len != 4) return error.Usage;
    const log = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        args[1],
        allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        0,
    );
    defer allocator.free(log);
    var parsed = try extract(allocator, log, args[2], try Kind.parse(args[3]));
    defer parsed.deinit();
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    var json: std.json.Stringify = .{
        .writer = &stdout_writer.interface,
        .options = .{ .escape_unicode = true },
    };
    try json.write(parsed.value);
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

const digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const commit = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const common_fixture =
    "\"runId\":\"run-1\",\"complete\":true,\"publishable\":true,\"publicationMode\":true," ++
    "\"expectedCases\":13,\"completedCases\":13,\"corpusCases\":13," ++
    "\"provider\":\"deepseek\",\"model\":\"deepseek-chat\",\"modelRevision\":null,\"providerRuntime\":null," ++
    "\"requestPolicy\":{\"maxOutputTokens\":8192,\"reserveTokens\":32768,\"stream\":false,\"purpose\":\"normal\",\"cachePolicy\":\"enabled\"}," ++
    "\"providerToolCount\":12,\"providerToolBytes\":4096,";

fn convergenceFixture(allocator: std.mem.Allocator) ![]u8 {
    return allocator.print("{{{s}\"corpusVersion\":\"{s}\",\"headlineInputHash\":\"{s}\",\"intentSuiteHash\":\"{s}\",\"securityProbeHash\":\"{s}\",\"thresholdHash\":\"{s}\",\"manifestHash\":\"{s}\",\"resultRunHash\":\"{s}\",\"promptPersonaHash\":\"{s}\",\"providerNeutralCatalogHash\":\"{s}\",\"providerSerializedCatalogHash\":\"{s}\",\"schemaHash\":\"{s}\",\"metaHash\":\"{s}\",\"grammarHash\":\"{s}\",\"semanticsHash\":\"{s}\",\"diagnosticHash\":\"{s}\",\"policyHash\":\"{s}\",\"sourceCommit\":\"{s}\",\"sourceDirty\":true,\"rawFirstDraftPassPercent\":69,\"rawFirstDraftPasses\":9,\"firstAttemptGreenPercent\":76,\"firstAttemptGreens\":10,\"finalGreenPercent\":100,\"finalGreens\":13,\"medianRoundtrips\":4,\"intentPassPercent\":100,\"intentPasses\":13,\"intentChecked\":13,\"emptyResponses\":0,\"timeoutFailures\":0,\"decodeFailures\":0}}", .{ common_fixture, digest, digest, digest, digest, digest, digest, digest, digest, digest, digest, digest, digest, digest, digest, digest, digest, commit });
}

fn coverageFixture(allocator: std.mem.Allocator) ![]u8 {
    return allocator.print("{{{s}\"corpusVersion\":\"{s}\",\"headlineInputHash\":\"{s}\",\"intentSuiteHash\":\"{s}\",\"securityProbeHash\":\"{s}\",\"thresholdHash\":\"{s}\",\"manifestHash\":\"{s}\",\"resultRunHash\":\"{s}\",\"promptPersonaHash\":\"{s}\",\"providerNeutralCatalogHash\":\"{s}\",\"providerSerializedCatalogHash\":\"{s}\",\"schemaHash\":\"{s}\",\"metaHash\":\"{s}\",\"grammarHash\":\"{s}\",\"semanticsHash\":\"{s}\",\"diagnosticHash\":\"{s}\",\"policyHash\":\"{s}\",\"sourceCommit\":\"{s}\",\"sourceDirty\":true,\"rulesTotal\":3,\"rulesTripped\":2,\"tripped\":[\"ZTS001\",\"ZTS002\"],\"untripped\":[\"ZTS003\"],\"offRegistry\":[\"ZTS900\"]}}", .{ common_fixture, digest, digest, digest, digest, digest, digest, digest, digest, digest, digest, digest, digest, digest, digest, digest, digest, commit });
}

fn parseFixture(allocator: std.mem.Allocator, encoded: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
}

fn probeValidFixtures() !void {
    const convergence = try convergenceFixture(std.testing.allocator);
    defer std.testing.allocator.free(convergence);
    const coverage = try coverageFixture(std.testing.allocator);
    defer std.testing.allocator.free(coverage);
    var parsed_convergence = try parseFixture(std.testing.allocator, convergence);
    defer parsed_convergence.deinit();
    var parsed_coverage = try parseFixture(std.testing.allocator, coverage);
    defer parsed_coverage.deinit();
    try validate(parsed_convergence.value, .convergence);
    try validate(parsed_coverage.value, .coverage);
}

fn probeMarkerExtraction() !void {
    const convergence = try convergenceFixture(std.testing.allocator);
    defer std.testing.allocator.free(convergence);
    const one = try std.testing.allocator.print("prefix [test-evidence] {s}\n", .{convergence});
    defer std.testing.allocator.free(one);
    var parsed = try extract(std.testing.allocator, one, "[test-evidence] ", .convergence);
    parsed.deinit();

    try std.testing.expectError(error.MissingOrDuplicateMarker, extract(std.testing.allocator, "ordinary output\n", "[test-evidence] ", .convergence));
    const two = try std.testing.allocator.print("[test-evidence] {s}\n[test-evidence] {s}\n", .{ convergence, convergence });
    defer std.testing.allocator.free(two);
    try std.testing.expectError(error.MissingOrDuplicateMarker, extract(std.testing.allocator, two, "[test-evidence] ", .convergence));
    try std.testing.expectError(error.MalformedJson, extract(std.testing.allocator, "[test-evidence] {\n", "[test-evidence] ", .convergence));
    try std.testing.expectError(error.MarkerIsNotObject, extract(std.testing.allocator, "[test-evidence] []\n", "[test-evidence] ", .convergence));
}

fn probeExactFields() !void {
    inline for (.{ Kind.convergence, Kind.coverage }) |kind| {
        const encoded = if (kind == .convergence)
            try convergenceFixture(std.testing.allocator)
        else
            try coverageFixture(std.testing.allocator);
        defer std.testing.allocator.free(encoded);
        const kind_fields: []const []const u8 = if (kind == .convergence) &convergence_fields else &coverage_fields;
        for (common_fields) |field| {
            var parsed = try parseFixture(std.testing.allocator, encoded);
            defer parsed.deinit();
            _ = parsed.value.object.orderedRemove(field);
            try std.testing.expectError(error.InvalidFields, validate(parsed.value, kind));
        }
        for (kind_fields) |field| {
            var parsed = try parseFixture(std.testing.allocator, encoded);
            defer parsed.deinit();
            _ = parsed.value.object.orderedRemove(field);
            try std.testing.expectError(error.InvalidFields, validate(parsed.value, kind));
        }
        var extra = try parseFixture(std.testing.allocator, encoded);
        defer extra.deinit();
        try extra.value.object.put(std.testing.allocator, "unknown", .{ .bool = true });
        try std.testing.expectError(error.InvalidFields, validate(extra.value, kind));
    }
}

fn expectCommonRefusal(field: []const u8, value: std.json.Value) !void {
    const encoded = try convergenceFixture(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var parsed = try parseFixture(std.testing.allocator, encoded);
    defer parsed.deinit();
    try parsed.value.object.put(std.testing.allocator, field, value);
    try std.testing.expectError(error.InvalidCommonEvidence, validate(parsed.value, .convergence));
}

fn probeCommonGuards() !void {
    for (digest_fields) |field| {
        try expectCommonRefusal(field, .{ .string = "not-a-digest" });
    }
    try expectCommonRefusal("complete", .{ .bool = false });
    try expectCommonRefusal("publishable", .{ .bool = false });
    try expectCommonRefusal("publicationMode", .{ .bool = false });
    try expectCommonRefusal("expectedCases", .{ .integer = 0 });
    try expectCommonRefusal("expectedCases", .{ .integer = 19 });
    try expectCommonRefusal("completedCases", .{ .integer = 12 });
    try expectCommonRefusal("corpusCases", .{ .string = "13" });
    try expectCommonRefusal("provider", .{ .string = "" });
    try expectCommonRefusal("model", .{ .string = "" });
    try expectCommonRefusal("modelRevision", .{ .string = "" });
    try expectCommonRefusal("providerRuntime", .{ .string = "mlx-lm" });
    try expectCommonRefusal("requestPolicy", .{ .object = .empty });
    try expectCommonRefusal("providerToolCount", .{ .integer = 0 });
    try expectCommonRefusal("providerToolBytes", .{ .integer = 0 });
    try expectCommonRefusal("sourceCommit", .{ .string = "unknown" });
    try expectCommonRefusal("sourceDirty", .{ .string = "yes" });
}

fn expectConvergenceRefusal(field: []const u8, value: std.json.Value) !void {
    const encoded = try convergenceFixture(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var parsed = try parseFixture(std.testing.allocator, encoded);
    defer parsed.deinit();
    try parsed.value.object.put(std.testing.allocator, field, value);
    try std.testing.expectError(error.InvalidConvergenceEvidence, validate(parsed.value, .convergence));
}

fn probeConvergenceGuards() !void {
    const invalid = [_]struct { []const u8, i64 }{
        .{ "rawFirstDraftPasses", 16 },
        .{ "rawFirstDraftPassPercent", 74 },
        .{ "firstAttemptGreens", 13 },
        .{ "firstAttemptGreenPercent", 79 },
        .{ "finalGreens", 14 },
        .{ "finalGreenPercent", 99 },
        .{ "medianRoundtrips", 0 },
        .{ "intentPasses", 14 },
        .{ "intentChecked", 12 },
        .{ "intentPassPercent", 99 },
        .{ "emptyResponses", 1 },
        .{ "timeoutFailures", 1 },
        .{ "decodeFailures", 1 },
    };
    for (invalid) |mutation| {
        try expectConvergenceRefusal(mutation[0], .{ .integer = mutation[1] });
    }

    for ([_]struct { []const u8, i64, []const u8, i64 }{
        .{ "rawFirstDraftPasses", 8, "rawFirstDraftPassPercent", 61 },
        .{ "finalGreens", 11, "finalGreenPercent", 84 },
        .{ "medianRoundtrips", 5, "medianRoundtrips", 5 },
        .{ "intentPasses", 10, "intentPassPercent", 76 },
    }) |mutations| {
        const encoded_allowed = try convergenceFixture(std.testing.allocator);
        defer std.testing.allocator.free(encoded_allowed);
        var allowed = try parseFixture(std.testing.allocator, encoded_allowed);
        defer allowed.deinit();
        try allowed.value.object.put(std.testing.allocator, mutations[0], .{ .integer = mutations[1] });
        try allowed.value.object.put(std.testing.allocator, mutations[2], .{ .integer = mutations[3] });
        try validate(allowed.value, .convergence);
    }

    const encoded_short = try convergenceFixture(std.testing.allocator);
    defer std.testing.allocator.free(encoded_short);
    var short = try parseFixture(std.testing.allocator, encoded_short);
    defer short.deinit();
    try short.value.object.put(std.testing.allocator, "intentPasses", .{ .integer = 12 });
    try short.value.object.put(std.testing.allocator, "intentChecked", .{ .integer = 12 });
    try std.testing.expectError(error.InvalidConvergenceEvidence, validate(short.value, .convergence));

    const encoded = try convergenceFixture(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var low = try parseFixture(std.testing.allocator, encoded);
    defer low.deinit();
    for ([_]struct { []const u8, i64 }{
        .{ "rawFirstDraftPassPercent", 7 },
        .{ "rawFirstDraftPasses", 1 },
        .{ "firstAttemptGreenPercent", 7 },
        .{ "firstAttemptGreens", 1 },
        .{ "finalGreenPercent", 7 },
        .{ "finalGreens", 1 },
        .{ "medianRoundtrips", 5 },
        .{ "intentPassPercent", 7 },
        .{ "intentPasses", 1 },
    }) |mutation| try low.value.object.put(std.testing.allocator, mutation[0], .{ .integer = mutation[1] });
    try validate(low.value, .convergence);

    var no_intent = try parseFixture(std.testing.allocator, encoded);
    defer no_intent.deinit();
    try no_intent.value.object.put(std.testing.allocator, "intentPassPercent", .{ .integer = 0 });
    try no_intent.value.object.put(std.testing.allocator, "intentPasses", .{ .integer = 0 });
    try validate(no_intent.value, .convergence);

    var no_green = try parseFixture(std.testing.allocator, encoded);
    defer no_green.deinit();
    for ([_][]const u8{ "rawFirstDraftPassPercent", "rawFirstDraftPasses", "firstAttemptGreenPercent", "firstAttemptGreens", "finalGreenPercent", "finalGreens" }) |field|
        try no_green.value.object.put(std.testing.allocator, field, .{ .integer = 0 });
    try validate(no_green.value, .convergence);
}

fn expectCoverageMutation(field: []const u8, replacement: []const u8) !void {
    const encoded = try coverageFixture(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var parsed = try parseFixture(std.testing.allocator, encoded);
    defer parsed.deinit();
    var replacement_parsed = try parseFixture(std.testing.allocator, replacement);
    defer replacement_parsed.deinit();
    try parsed.value.object.put(std.testing.allocator, field, replacement_parsed.value);
    try std.testing.expectError(error.InvalidCoverageEvidence, validate(parsed.value, .coverage));
}

fn probeCoverageGuards() !void {
    try expectCoverageMutation("rulesTotal", "0");
    try expectCoverageMutation("rulesTripped", "0");
    try expectCoverageMutation("rulesTripped", "1");
    try expectCoverageMutation("rulesTripped", "-1");
    try expectCoverageMutation("tripped", "[\"ZTS001\",\"ZTS001\"]");
    try expectCoverageMutation("untripped", "[\"ZTS002\"]");
    try expectCoverageMutation("offRegistry", "[\"ZTS001\"]");
}

test "zero coverage retains complete corpus and complete rule partition" {
    const a = std.testing.allocator;
    const encoded = try coverageFixture(a);
    defer a.free(encoded);
    var parsed = try parseFixture(a, encoded);
    defer parsed.deinit();
    const all = try std.json.parseFromSlice(std.json.Value, a, "[\"ZTS001\",\"ZTS002\",\"ZTS003\"]", .{});
    defer all.deinit();
    parsed.value.object.getPtr("rulesTripped").?.* = .{ .integer = 0 };
    parsed.value.object.getPtr("tripped").?.* = .{ .array = std.json.Array.init(a) };
    parsed.value.object.getPtr("untripped").?.* = all.value;
    try validate(parsed.value, .coverage);
    parsed.value.object.getPtr("completedCases").?.* = .{ .integer = 12 };
    try std.testing.expectError(error.InvalidCommonEvidence, validate(parsed.value, .coverage));
    parsed.value.object.getPtr("completedCases").?.* = .{ .integer = 13 };
    parsed.value.object.getPtr("untripped").?.* = .{ .array = std.json.Array.init(a) };
    try std.testing.expectError(error.InvalidCoverageEvidence, validate(parsed.value, .coverage));
}

test "native marker probe suites complete" {
    try probeValidFixtures();
    try probeMarkerExtraction();
    try probeExactFields();
    try probeCommonGuards();
    try probeConvergenceGuards();
    try probeCoverageGuards();
    try std.testing.expectError(error.UnknownEvidenceKind, Kind.parse("unknown"));

    const convergence = try convergenceFixture(std.testing.allocator);
    defer std.testing.allocator.free(convergence);
    const coverage = try coverageFixture(std.testing.allocator);
    defer std.testing.allocator.free(coverage);
    std.debug.print("[evidence-fixture-convergence] {s}\n", .{convergence});
    std.debug.print("[evidence-fixture-coverage] {s}\n", .{coverage});
    std.debug.print(
        "[evidence-marker-probes] complete: exact fields, marker count, JSON, identity, counts, types, digests, measurements, and partitions\n",
        .{},
    );
}

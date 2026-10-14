//! Structured readers for repository verification gates.
//!
//! The shell entry points keep command execution and temporary-file handling.
//! This command owns structured JSON and release-workflow validation.

const std = @import("std");

const max_input_bytes = 16 * 1024 * 1024;

const ReleaseFailure = error{
    MissingTestJob,
    InvalidOsMatrix,
    MissingMacos,
    InvalidBenchmarkStepCount,
    InvalidBenchmarkCondition,
    BenchmarkMustBeAdvisory,
};

fn releaseMessage(failure: ReleaseFailure) []const u8 {
    return switch (failure) {
        error.MissingTestJob => "release workflow: missing test job",
        error.InvalidOsMatrix => "release workflow: expected one test matrix os row",
        error.MissingMacos => "release workflow: test matrix must include macos-latest",
        error.InvalidBenchmarkStepCount => "release workflow: expected exactly one zig build bench-check step",
        error.InvalidBenchmarkCondition => "release workflow: advisory bench-check must run on macos-latest",
        error.BenchmarkMustBeAdvisory => "release workflow: machine-local bench-check must be advisory",
    };
}

fn collectArgs(allocator: std.mem.Allocator, vector: std.process.Args) ![]const []const u8 {
    var iterator = std.process.Args.Iterator.init(vector);
    defer iterator.deinit();
    var args: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    while (iterator.next()) |arg| try args.append(allocator, try allocator.dupe(u8, arg));
    return args.toOwnedSlice(allocator);
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(max_input_bytes),
        .of(u8),
        0,
    );
}

fn isNonEmptyString(value: ?std.json.Value) bool {
    const actual = value orelse return false;
    return actual == .string and actual.string.len != 0;
}

fn isLowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn requireString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MissingField;
    if (value != .string or value.string.len == 0) return error.InvalidField;
    return value.string;
}

fn requireExactFields(object: std.json.ObjectMap, fields: []const []const u8) !void {
    if (object.count() != fields.len) return error.InvalidFields;
    for (fields) |field| {
        if (!object.contains(field)) return error.InvalidFields;
    }
}

const envelope_fields = [_][]const u8{
    "schema_version",
    "operation",
    "profile_id",
    "compiler_version",
    "policy_version",
    "policy_hash",
    "module_graph_hash",
    "success",
    "payload",
    "diagnostics",
};

fn validateNegotiation(value: std.json.Value) !void {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidEnvelope,
    };
    try requireExactFields(object, &.{
        "schema_version_unsupported",
        "supported_schema_versions",
        "compiler_version",
    });
    const unsupported = object.get("schema_version_unsupported") orelse return error.InvalidEnvelope;
    if (unsupported != .bool or !unsupported.bool) return error.InvalidEnvelope;
    const versions = object.get("supported_schema_versions") orelse return error.InvalidEnvelope;
    if (versions != .array or versions.array.items.len == 0) return error.InvalidEnvelope;
    for (versions.array.items) |version| {
        if (version != .integer) return error.InvalidEnvelope;
    }
    if (!isNonEmptyString(object.get("compiler_version"))) return error.InvalidEnvelope;
}

fn validateEnvelope(value: std.json.Value, operation: []const u8) !void {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidEnvelope,
    };
    const success_value = object.get("success") orelse return error.InvalidEnvelope;
    if (success_value != .bool) return error.InvalidEnvelope;
    const expected_count: usize = envelope_fields.len + @intFromBool(!success_value.bool);
    if (object.count() != expected_count) return error.InvalidEnvelope;
    for (envelope_fields) |field| {
        if (!object.contains(field)) return error.InvalidEnvelope;
    }

    const schema = object.get("schema_version") orelse return error.InvalidEnvelope;
    if (schema != .integer or schema.integer != 2) return error.InvalidEnvelope;
    const emitted_operation = try requireString(object, "operation");
    if (!std.mem.eql(u8, emitted_operation, operation)) return error.InvalidEnvelope;
    if (!isNonEmptyString(object.get("profile_id")) or
        !isNonEmptyString(object.get("compiler_version")) or
        !isNonEmptyString(object.get("policy_version"))) return error.InvalidEnvelope;

    const policy_hash = try requireString(object, "policy_hash");
    const graph_hash = try requireString(object, "module_graph_hash");
    if (!isLowerHex(policy_hash, 64) or !isLowerHex(graph_hash, 64)) return error.InvalidEnvelope;

    const payload = object.get("payload") orelse return error.InvalidEnvelope;
    const diagnostics = object.get("diagnostics") orelse return error.InvalidEnvelope;
    if (payload != .object or diagnostics != .array) return error.InvalidEnvelope;

    if (std.mem.eql(u8, operation, "nope")) {
        if (success_value.bool) return error.InvalidEnvelope;
        const error_value = object.get("error") orelse return error.InvalidEnvelope;
        const error_object = switch (error_value) {
            .object => |error_object| error_object,
            else => return error.InvalidEnvelope,
        };
        try requireExactFields(error_object, &.{ "code", "message", "field" });
        const code = try requireString(error_object, "code");
        if (!std.mem.eql(u8, code, "unknown_operation")) return error.InvalidEnvelope;
        if (!isNonEmptyString(error_object.get("message"))) return error.InvalidEnvelope;
        const field = error_object.get("field") orelse return error.InvalidEnvelope;
        if (field != .string and field != .null) return error.InvalidEnvelope;
    } else {
        if (!success_value.bool or object.contains("error")) return error.InvalidEnvelope;
    }
}

fn validateAgentFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    label: []const u8,
    path: []const u8,
) !void {
    const bytes = try readFile(io, allocator, path);
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
        return error.MalformedJson;
    defer parsed.deinit();
    if (std.mem.eql(u8, label, "negotiation")) {
        try validateNegotiation(parsed.value);
    } else {
        try validateEnvelope(parsed.value, label);
    }
}

const MetaPins = struct {
    profile: []const u8,
    policy: []const u8,
    grammar: []const u8,
    idiom: []const u8,
    restriction: []const u8,
    builtin: []const u8,
};

fn comparePin(name: []const u8, got: []const u8, want: []const u8) !void {
    if (std.mem.eql(u8, got, want)) return;
    std.debug.print(
        "meta drift: {s} moved\n  published: {s}\n  pinned:    {s}\n" ++
            "If the move was intended, update this script in the same commit and say what moved.\n",
        .{ name, got, want },
    );
    return error.PinMoved;
}

fn validateMeta(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    pins: MetaPins,
) !void {
    const bytes = try readFile(io, allocator, path);
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
        return error.MalformedJson;
    defer parsed.deinit();
    try validateMetaValue(parsed.value, pins);
}

fn validateMetaValue(value: std.json.Value, pins: MetaPins) !void {
    try validateEnvelope(value, "meta");
    const envelope = value.object;
    const payload_value = envelope.get("payload") orelse return error.MissingField;
    const payload = switch (payload_value) {
        .object => |object| object,
        else => return error.InvalidField,
    };
    const profile = try requireString(payload, "profile_id");
    const policy = try requireString(payload, "policy_hash");
    const grammar = try requireString(payload, "grammar_hash");
    const idiom = try requireString(payload, "idiom_table_hash");
    const restriction = try requireString(payload, "restriction_matrix_hash");
    const builtin = try requireString(payload, "builtin_registry_hash");
    const frontends = payload.get("source_frontends") orelse return error.MissingField;
    if (frontends != .array or frontends.array.items.len != 0) return error.SourceFrontendsNotEmpty;

    try comparePin("profile_id", profile, pins.profile);
    try comparePin("policy_hash", policy, pins.policy);
    try comparePin("grammar_hash", grammar, pins.grammar);
    try comparePin("idiom_table_hash", idiom, pins.idiom);
    try comparePin("restriction_matrix_hash", restriction, pins.restriction);
    try comparePin("builtin_registry_hash", builtin, pins.builtin);
}

fn lineEquals(line: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), expected);
}

const LineRange = struct { start: usize, end: usize };

fn findTestJob(lines: []const []const u8) ReleaseFailure!LineRange {
    var start: ?usize = null;
    for (lines, 0..) |line, index| {
        if (lineEquals(line, "  test:")) {
            start = index;
            break;
        }
    }
    const first = start orelse return error.MissingTestJob;
    var end = lines.len;
    for (lines[first + 1 ..], first + 1..) |raw, index| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "  ") and
            !std.mem.startsWith(u8, line, "    ") and
            std.mem.endsWith(u8, line, ":"))
        {
            end = index;
            break;
        }
    }
    return .{ .start = first, .end = end };
}

fn validateOsMatrix(job: []const []const u8) ReleaseFailure!void {
    var row: ?[]const u8 = null;
    var count: usize = 0;
    for (job) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "        os: [")) {
            count += 1;
            row = line;
        }
    }
    if (count != 1) return error.InvalidOsMatrix;
    const line = row.?;
    const open = std.mem.findScalar(u8, line, '[') orelse return error.InvalidOsMatrix;
    const close = std.mem.findScalarLast(u8, line, ']') orelse return error.InvalidOsMatrix;
    if (close <= open) return error.InvalidOsMatrix;
    var values = std.mem.splitScalar(u8, line[open + 1 .. close], ',');
    while (values.next()) |raw| {
        const value = std.mem.trim(u8, raw, " \t'\"");
        if (std.mem.eql(u8, value, "macos-latest")) return;
    }
    return error.MissingMacos;
}

fn validateBenchmarkStep(job: []const []const u8) ReleaseFailure!void {
    var step_start: ?usize = null;
    var step_end: usize = 0;
    var matches: usize = 0;
    var index: usize = 0;
    while (index < job.len) : (index += 1) {
        if (!std.mem.startsWith(u8, job[index], "      - ")) continue;
        var end = index + 1;
        while (end < job.len and !std.mem.startsWith(u8, job[end], "      - ")) : (end += 1) {}
        var contains_run = false;
        for (job[index..end]) |raw| {
            if (lineEquals(raw, "        run: zig build bench-check")) contains_run = true;
        }
        if (contains_run) {
            matches += 1;
            step_start = index;
            step_end = end;
        }
        index = end - 1;
    }
    if (matches != 1) return error.InvalidBenchmarkStepCount;
    const step = job[step_start.?..step_end];
    var condition = false;
    var advisory = false;
    for (step) |raw| {
        condition = condition or lineEquals(raw, "        if: ${{ matrix.os == 'macos-latest' }}");
        advisory = advisory or lineEquals(raw, "        continue-on-error: true");
    }
    if (!condition) return error.InvalidBenchmarkCondition;
    if (!advisory) return error.BenchmarkMustBeAdvisory;
}

fn validateReleaseWorkflow(source: []const u8) ReleaseFailure!void {
    var lines_list: std.ArrayList([]const u8) = .empty;
    defer lines_list.deinit(std.heap.smp_allocator);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| lines_list.append(std.heap.smp_allocator, line) catch
        return error.InvalidBenchmarkStepCount;
    const range = try findTestJob(lines_list.items);
    const job = lines_list.items[range.start..range.end];
    try validateOsMatrix(job);
    try validateBenchmarkStep(job);
}

fn expectReleaseFailure(source: []const u8, expected: ReleaseFailure) !void {
    validateReleaseWorkflow(source) catch |actual| {
        if (actual == expected) return;
        return error.NegativeFixtureChanged;
    };
    return error.NegativeFixturePassed;
}

const unnamed_blocking_fixture =
    \\jobs:
    \\  test:
    \\    strategy:
    \\      matrix:
    \\        os: [macos-latest, ubuntu-latest]
    \\    steps:
    \\      - name: Earlier advisory step
    \\        continue-on-error: true
    \\        run: true
    \\      - id: benchmark
    \\        if: ${{ matrix.os == 'macos-latest' }}
    \\        run: zig build bench-check
;

const disabled_fixture =
    \\jobs:
    \\  test:
    \\    strategy:
    \\      matrix:
    \\        os: [macos-latest, ubuntu-latest]
    \\    steps:
    \\      - name: Disabled benchmark
    \\        if: false
    \\        continue-on-error: true
    \\        run: zig build bench-check
;

const ubuntu_only_fixture =
    \\jobs:
    \\  test:
    \\    strategy:
    \\      matrix:
    \\        os: [ubuntu-latest]
    \\    steps:
    \\      - name: Advisory benchmark
    \\        if: ${{ matrix.os == 'macos-latest' }}
    \\        continue-on-error: true
    \\        run: zig build bench-check
;

fn runReleaseWorkflow(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    try expectReleaseFailure(unnamed_blocking_fixture, error.BenchmarkMustBeAdvisory);
    try expectReleaseFailure(disabled_fixture, error.InvalidBenchmarkCondition);
    try expectReleaseFailure(ubuntu_only_fixture, error.MissingMacos);
    const source = try readFile(io, allocator, path);
    defer allocator.free(source);
    validateReleaseWorkflow(source) catch |failure| {
        std.debug.print("{s}\n", .{releaseMessage(failure)});
        return error.ReleaseWorkflowFailed;
    };
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn usage() noreturn {
    std.debug.print(
        "usage: repo-gate <agent-envelope|meta-drift|release-workflow> ...\n",
        .{},
    );
    std.process.exit(2);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
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
    if (args.len < 2) usage();

    if (std.mem.eql(u8, args[1], "agent-envelope")) {
        if (args.len != 4) usage();
        validateAgentFile(io, allocator, args[2], args[3]) catch |failure| {
            std.debug.print("agent determinism: {s} response is not a complete schema-2 envelope: {s}\n", .{ args[2], @errorName(failure) });
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, args[1], "meta-drift")) {
        if (args.len != 9) usage();
        validateMeta(io, allocator, args[2], .{
            .profile = args[3],
            .policy = args[4],
            .grammar = args[5],
            .idiom = args[6],
            .restriction = args[7],
            .builtin = args[8],
        }) catch |failure| {
            if (failure != error.PinMoved) {
                std.debug.print("meta drift: response validation failed: {s}\n", .{@errorName(failure)});
            }
            std.process.exit(1);
        };
        try writeStdout(io, "meta drift OK (core profile and five registry hashes match their pins; source frontends empty)\n");
        return;
    }
    if (std.mem.eql(u8, args[1], "release-workflow")) {
        if (args.len != 3) usage();
        runReleaseWorkflow(io, allocator, args[2]) catch |failure| {
            if (failure != error.ReleaseWorkflowFailed) {
                std.debug.print("release workflow: native validation failed: {s}\n", .{@errorName(failure)});
            }
            std.process.exit(1);
        };
        try writeStdout(io, "release workflow: advisory benchmark gate OK\n");
        return;
    }
    usage();
}

test "release workflow negative fixtures preserve each refusal" {
    try expectReleaseFailure(unnamed_blocking_fixture, error.BenchmarkMustBeAdvisory);
    try expectReleaseFailure(disabled_fixture, error.InvalidBenchmarkCondition);
    try expectReleaseFailure(ubuntu_only_fixture, error.MissingMacos);
}

test "complete schema-2 envelope requires every identity field" {
    const valid =
        \\{"schema_version":2,"operation":"meta","profile_id":"zts-model-1","compiler_version":"1","policy_version":"1","policy_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","module_graph_hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","success":true,"payload":{},"diagnostics":[]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, valid, .{});
    defer parsed.deinit();
    try validateEnvelope(parsed.value, "meta");
}

test "metadata requires an empty source frontend list" {
    const hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const valid =
        \\{"schema_version":2,"operation":"meta","profile_id":"zts-model-1","compiler_version":"1","policy_version":"1","policy_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","module_graph_hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","success":true,"payload":{"profile_id":"zts-model-1","policy_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","grammar_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","idiom_table_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","restriction_matrix_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","builtin_registry_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_frontends":[]},"diagnostics":[]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, valid, .{});
    defer parsed.deinit();
    try validateMetaValue(parsed.value, .{
        .profile = "zts-model-1",
        .policy = hash,
        .grammar = hash,
        .idiom = hash,
        .restriction = hash,
        .builtin = hash,
    });
}

test "post-cut meta rejects a surviving source frontend" {
    const value =
        \\{"schema_version":2,"operation":"meta","profile_id":"zts-model-1","compiler_version":"1","policy_version":"1","policy_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","module_graph_hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","success":true,"payload":{"profile_id":"zts-model-1","policy_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","grammar_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","idiom_table_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","restriction_matrix_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","builtin_registry_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_frontends":[{"profile_id":"old"}]},"diagnostics":[]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, value, .{});
    defer parsed.deinit();
    const hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectError(error.SourceFrontendsNotEmpty, validateMetaValue(parsed.value, .{
        .profile = "zts-model-1",
        .policy = hash,
        .grammar = hash,
        .idiom = hash,
        .restriction = hash,
        .builtin = hash,
    }));
}

test "unknown operation remains a complete error envelope" {
    const value =
        \\{"schema_version":2,"operation":"nope","profile_id":"zts-model-1","compiler_version":"1","policy_version":"1","policy_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","module_graph_hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","success":false,"payload":{},"diagnostics":[],"error":{"code":"unknown_operation","message":"unknown operation","field":"operation"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, value, .{});
    defer parsed.deinit();
    try validateEnvelope(parsed.value, "nope");
}

const valid_meta_envelope =
    \\{"schema_version":2,"operation":"meta","profile_id":"zts-model-1","compiler_version":"1","policy_version":"1","policy_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","module_graph_hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","success":true,"payload":{},"diagnostics":[]}
;

fn expectEnvelopeRefusal(from: []const u8, to: []const u8) !void {
    const mutated = try std.mem.replaceOwned(u8, std.testing.allocator, valid_meta_envelope, from, to);
    defer std.testing.allocator.free(mutated);
    // The mutation must change the text, or the case would re-test the valid envelope.
    try std.testing.expect(!std.mem.eql(u8, mutated, valid_meta_envelope));
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mutated, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidEnvelope, validateEnvelope(parsed.value, "meta"));
}

test "envelope validator refuses each broken identity field" {
    const short_hash = "\"policy_hash\":\"aaaa\"";
    const upper_hash = "\"policy_hash\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"";
    const full_hash = "\"policy_hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"";
    try expectEnvelopeRefusal("\"schema_version\":2", "\"schema_version\":3");
    try expectEnvelopeRefusal("\"operation\":\"meta\"", "\"operation\":\"other\"");
    try expectEnvelopeRefusal("\"profile_id\":\"zts-model-1\"", "\"profile_id\":\"\"");
    try expectEnvelopeRefusal("\"compiler_version\":\"1\"", "\"compiler_version\":\"\"");
    try expectEnvelopeRefusal("\"policy_version\":\"1\"", "\"policy_version\":\"\"");
    try expectEnvelopeRefusal(full_hash, short_hash);
    try expectEnvelopeRefusal(full_hash, upper_hash);
    try expectEnvelopeRefusal("\"module_graph_hash\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"", "\"module_graph_hash\":\"bb\"");
    try expectEnvelopeRefusal("\"payload\":{}", "\"payload\":[]");
    try expectEnvelopeRefusal("\"diagnostics\":[]", "\"diagnostics\":{}");
    try expectEnvelopeRefusal("\"success\":true", "\"success\":false");
    try expectEnvelopeRefusal("\"diagnostics\":[]", "\"diagnostics\":[],\"error\":{}");
    try expectEnvelopeRefusal("\"diagnostics\":[]", "\"extra\":1");
}

test "meta drift names every moved pin" {
    const hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const other = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const value =
        \\{"schema_version":2,"operation":"meta","profile_id":"zts-model-1","compiler_version":"1","policy_version":"1","policy_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","module_graph_hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","success":true,"payload":{"profile_id":"zts-model-1","policy_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","grammar_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","idiom_table_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","restriction_matrix_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","builtin_registry_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_frontends":[]},"diagnostics":[]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, value, .{});
    defer parsed.deinit();
    const base: MetaPins = .{
        .profile = "zts-model-1",
        .policy = hash,
        .grammar = hash,
        .idiom = hash,
        .restriction = hash,
        .builtin = hash,
    };
    var profile = base;
    profile.profile = "other-profile";
    var policy = base;
    policy.policy = other;
    var grammar = base;
    grammar.grammar = other;
    var idiom = base;
    idiom.idiom = other;
    var restriction = base;
    restriction.restriction = other;
    var builtin = base;
    builtin.builtin = other;
    const moved = [_]MetaPins{ profile, policy, grammar, idiom, restriction, builtin };
    try std.testing.expectEqual(@as(usize, 6), moved.len);
    for (moved) |pins| {
        try std.testing.expectError(error.PinMoved, validateMetaValue(parsed.value, pins));
    }
}

test "negotiation validator accepts one shape and refuses broken fields" {
    const valid =
        \\{"schema_version_unsupported":true,"supported_schema_versions":[2],"compiler_version":"1"}
    ;
    const broken = [_][]const u8{
        \\{"schema_version_unsupported":false,"supported_schema_versions":[2],"compiler_version":"1"}
        ,
        \\{"schema_version_unsupported":true,"supported_schema_versions":[],"compiler_version":"1"}
        ,
        \\{"schema_version_unsupported":true,"supported_schema_versions":["2"],"compiler_version":"1"}
        ,
        \\{"schema_version_unsupported":true,"supported_schema_versions":[2],"compiler_version":""}
        ,
    };
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, valid, .{});
        defer parsed.deinit();
        try validateNegotiation(parsed.value);
    }
    for (broken) |text| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidEnvelope, validateNegotiation(parsed.value));
    }
    var extra = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"schema_version_unsupported":true,"supported_schema_versions":[2],"compiler_version":"1","extra":1}
    , .{});
    defer extra.deinit();
    try std.testing.expectError(error.InvalidFields, validateNegotiation(extra.value));
}

const good_workflow_fixture =
    \\jobs:
    \\  test:
    \\    strategy:
    \\      matrix:
    \\        os: [macos-latest, ubuntu-latest]
    \\    steps:
    \\      - name: Advisory benchmark
    \\        if: ${{ matrix.os == 'macos-latest' }}
    \\        continue-on-error: true
    \\        run: zig build bench-check
;

test "release workflow accepts the advisory macos benchmark shape" {
    try validateReleaseWorkflow(good_workflow_fixture);
}

test "release workflow refuses a missing job, a doubled matrix row, and a wrong step count" {
    try expectReleaseFailure("jobs:\n  build:\n    steps: []\n", error.MissingTestJob);
    const two_rows =
        \\jobs:
        \\  test:
        \\    strategy:
        \\      matrix:
        \\        os: [macos-latest]
        \\        os: [macos-latest]
    ;
    try expectReleaseFailure(two_rows, error.InvalidOsMatrix);
    const no_step =
        \\jobs:
        \\  test:
        \\    strategy:
        \\      matrix:
        \\        os: [macos-latest]
        \\    steps:
        \\      - run: true
    ;
    try expectReleaseFailure(no_step, error.InvalidBenchmarkStepCount);
    const two_steps = good_workflow_fixture ++
        \\
        \\      - name: Second benchmark
        \\        if: ${{ matrix.os == 'macos-latest' }}
        \\        continue-on-error: true
        \\        run: zig build bench-check
    ;
    try expectReleaseFailure(two_steps, error.InvalidBenchmarkStepCount);
}

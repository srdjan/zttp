//! Structured readers for repository verification gates.
//!
//! The shell entry points keep command execution and temporary-file handling.
//! This command owns structured JSON and release-script validation.

const std = @import("std");

const max_input_bytes = 16 * 1024 * 1024;

const ReleaseFailure = error{
    MissingHostVerify,
    MissingContainerVerify,
    InvalidBenchmarkStepCount,
    BenchmarkMustBeAdvisory,
    MissingSmokeGettingStarted,
    MissingReleaseCheck,
    MissingReleaseTarget,
    IntelMacosTarget,
    ReleaseNotDraft,
};

fn releaseMessage(failure: ReleaseFailure) []const u8 {
    return switch (failure) {
        error.MissingHostVerify => "release script: missing a `bash scripts/verify.sh --release` host gate",
        error.MissingContainerVerify => "release script: missing a `container run --arch amd64` line that runs `scripts/verify.sh --release`",
        error.InvalidBenchmarkStepCount => "release script: expected exactly one zig build bench-check line",
        error.BenchmarkMustBeAdvisory => "release script: machine-local bench-check must be advisory (`||`)",
        error.MissingSmokeGettingStarted => "release script: missing `zig build smoke-getting-started`",
        error.MissingReleaseCheck => "release script: missing `zig build release-check`",
        error.MissingReleaseTarget => "release script: a release target (x86_64-linux-gnu, aarch64-linux-gnu, aarch64-macos-none) is missing",
        error.IntelMacosTarget => "release script: x86_64-macos-none must not be built; no Intel macOS binary is published",
        error.ReleaseNotDraft => "release script: every `gh release create` must create a draft (`--draft`)",
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

/// Join backslash-continued physical lines into logical lines and drop
/// comments, so a rule cannot be satisfied by text the shell never runs. A line
/// whose first non-space character is `#` is a comment, including inside a
/// continuation (the shell ends the logical line at the comment). A trailing
/// comment after a command is not stripped: the rules below are text checks and
/// do not parse shell quoting.
fn normalizeScript(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var logical: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (logical.items) |line| allocator.free(line);
        logical.deinit(allocator);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var physical = std.mem.splitScalar(u8, source, '\n');
    while (physical.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const is_comment = std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "#");
        const continues = !is_comment and std.mem.endsWith(u8, line, "\\");
        if (!is_comment) {
            const text = if (continues) line[0 .. line.len - 1] else line;
            try current.appendSlice(allocator, text);
            if (continues) try current.append(allocator, ' ');
        }
        if (continues) continue;
        if (current.items.len != 0) {
            const owned = try allocator.dupe(u8, current.items);
            errdefer allocator.free(owned);
            try logical.append(allocator, owned);
            current.clearRetainingCapacity();
        }
    }
    if (current.items.len != 0) {
        const owned = try allocator.dupe(u8, current.items);
        errdefer allocator.free(owned);
        try logical.append(allocator, owned);
    }
    return logical.toOwnedSlice(allocator);
}

fn anyLineContains(lines: []const []const u8, needle: []const u8) bool {
    for (lines) |line| {
        if (std.mem.find(u8, line, needle) != null) return true;
    }
    return false;
}

fn validateReleaseLines(lines: []const []const u8) ReleaseFailure!void {
    var host_verify = false;
    var container_verify = false;
    var bench_lines: usize = 0;
    var bench_advisory = false;
    var create_lines: usize = 0;
    var create_drafts: usize = 0;
    for (lines) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "bash scripts/verify.sh --release")) host_verify = true;
        if (std.mem.find(u8, line, "container run") != null and
            std.mem.find(u8, line, "--arch amd64") != null and
            std.mem.find(u8, line, "scripts/verify.sh --release") != null) container_verify = true;
        if (std.mem.find(u8, line, "zig build bench-check") != null) {
            bench_lines += 1;
            bench_advisory = std.mem.find(u8, line, "||") != null;
        }
        if (std.mem.find(u8, line, "gh release create") != null) {
            create_lines += 1;
            if (std.mem.find(u8, line, "--draft") != null) create_drafts += 1;
        }
    }
    if (!host_verify) return error.MissingHostVerify;
    if (!container_verify) return error.MissingContainerVerify;
    if (bench_lines != 1) return error.InvalidBenchmarkStepCount;
    if (!bench_advisory) return error.BenchmarkMustBeAdvisory;
    if (!anyLineContains(lines, "zig build smoke-getting-started")) return error.MissingSmokeGettingStarted;
    if (!anyLineContains(lines, "zig build release-check")) return error.MissingReleaseCheck;
    for ([_][]const u8{ "x86_64-linux-gnu", "aarch64-linux-gnu", "aarch64-macos-none" }) |target| {
        if (!anyLineContains(lines, target)) return error.MissingReleaseTarget;
    }
    if (anyLineContains(lines, "x86_64-macos-none")) return error.IntelMacosTarget;
    // At least one create line, and no create line without --draft: a script
    // that never creates a release has nothing to publish.
    if (create_lines == 0 or create_drafts != create_lines) return error.ReleaseNotDraft;
}

fn validateReleaseScript(allocator: std.mem.Allocator, source: []const u8) (ReleaseFailure || std.mem.Allocator.Error)!void {
    const lines = try normalizeScript(allocator, source);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }
    try validateReleaseLines(lines);
}

fn expectReleaseFailure(allocator: std.mem.Allocator, source: []const u8, expected: ReleaseFailure) !void {
    validateReleaseScript(allocator, source) catch |actual| {
        if (actual == expected) return;
        return error.NegativeFixtureChanged;
    };
    return error.NegativeFixturePassed;
}

const container_block =
    \\container run --rm --arch amd64 --rosetta \
    \\  -v "$repo":/src:ro "$image" \
    \\  bash -c "git clone -q /src /work && cd /work && bash scripts/verify.sh --release"
;

/// The smallest script that satisfies every rule. Each negative case below is
/// this text plus one edit.
const positive_fixture =
    \\#!/usr/bin/env bash
    \\# A comment naming x86_64-macos-none is not a target.
    \\bash scripts/verify.sh --release
    \\zig build smoke-getting-started
    \\zig build bench-check || echo "warning: advisory bench-check missed"
    \\zig build release-check -- --json
    \\targets=(
    \\  "x86_64-linux-gnu:linux:x86_64"
    \\  "aarch64-linux-gnu:linux:aarch64"
    \\  "aarch64-macos-none:macos:aarch64"
    \\)
++ "\n" ++ container_block ++ "\n" ++
    \\gh release create "$tag" --draft --verify-tag
;

const NegativeCase = struct {
    name: []const u8,
    from: []const u8,
    to: []const u8,
    expected: ReleaseFailure,
};

const negative_cases = [_]NegativeCase{
    .{ .name = "host verify commented out", .from = "\nbash scripts/verify.sh --release\n", .to = "\n# bash scripts/verify.sh --release\n", .expected = error.MissingHostVerify },
    .{ .name = "host verify absent", .from = "\nbash scripts/verify.sh --release\n", .to = "\n", .expected = error.MissingHostVerify },
    .{ .name = "host verify without the release flag", .from = "\nbash scripts/verify.sh --release\n", .to = "\nbash scripts/verify.sh\n", .expected = error.MissingHostVerify },
    .{ .name = "container verify only in a comment", .from = container_block, .to = "# container run --rm --arch amd64 bash -c \"bash scripts/verify.sh --release\"", .expected = error.MissingContainerVerify },
    .{ .name = "container verify on arm64", .from = "--arch amd64", .to = "--arch arm64", .expected = error.MissingContainerVerify },
    .{ .name = "container verify without the release flag", .from = "scripts/verify.sh --release\"", .to = "scripts/verify.sh\"", .expected = error.MissingContainerVerify },
    .{ .name = "benchmark absent", .from = "zig build bench-check || echo \"warning: advisory bench-check missed\"\n", .to = "", .expected = error.InvalidBenchmarkStepCount },
    .{ .name = "benchmark only in a comment", .from = "zig build bench-check ||", .to = "# zig build bench-check ||", .expected = error.InvalidBenchmarkStepCount },
    .{ .name = "benchmark twice", .from = "zig build bench-check || echo \"warning: advisory bench-check missed\"\n", .to = "zig build bench-check || true\nzig build bench-check || true\n", .expected = error.InvalidBenchmarkStepCount },
    .{ .name = "benchmark blocks the release", .from = " || echo \"warning: advisory bench-check missed\"", .to = "", .expected = error.BenchmarkMustBeAdvisory },
    .{ .name = "smoke absent", .from = "zig build smoke-getting-started\n", .to = "", .expected = error.MissingSmokeGettingStarted },
    .{ .name = "smoke only in a comment", .from = "zig build smoke-getting-started\n", .to = "# zig build smoke-getting-started\n", .expected = error.MissingSmokeGettingStarted },
    .{ .name = "release check absent", .from = "zig build release-check -- --json\n", .to = "", .expected = error.MissingReleaseCheck },
    .{ .name = "x86_64 linux target absent", .from = "x86_64-linux-gnu", .to = "x86_64-linux-musl", .expected = error.MissingReleaseTarget },
    .{ .name = "aarch64 linux target absent", .from = "aarch64-linux-gnu", .to = "aarch64-linux-musl", .expected = error.MissingReleaseTarget },
    .{ .name = "aarch64 macos target absent", .from = "aarch64-macos-none", .to = "aarch64-macos-gnu", .expected = error.MissingReleaseTarget },
    .{ .name = "intel macos target added", .from = "  \"aarch64-macos-none:macos:aarch64\"\n", .to = "  \"aarch64-macos-none:macos:aarch64\"\n  \"x86_64-macos-none:macos:x86_64\"\n", .expected = error.IntelMacosTarget },
    .{ .name = "release is not a draft", .from = " --draft", .to = "", .expected = error.ReleaseNotDraft },
    .{ .name = "release never created", .from = "gh release create \"$tag\" --draft --verify-tag", .to = "echo release", .expected = error.ReleaseNotDraft },
    .{ .name = "second create is not a draft", .from = "gh release create \"$tag\" --draft --verify-tag", .to = "gh release create \"$tag\" --draft --verify-tag\ngh release create \"$tag\"", .expected = error.ReleaseNotDraft },
};

fn expectNegativeCase(allocator: std.mem.Allocator, case: NegativeCase) !void {
    const mutated = try std.mem.replaceOwned(u8, allocator, positive_fixture, case.from, case.to);
    defer allocator.free(mutated);
    // The edit must change the text, or the case would re-test the positive fixture.
    if (std.mem.eql(u8, mutated, positive_fixture)) {
        std.debug.print("release workflow: negative case '{s}' does not change the fixture\n", .{case.name});
        return error.NegativeFixtureUnchanged;
    }
    expectReleaseFailure(allocator, mutated, case.expected) catch |failure| {
        std.debug.print("release workflow: negative case '{s}' did not produce {s}\n", .{ case.name, @errorName(case.expected) });
        return failure;
    };
}

/// Run the positive fixture and every negative case, and require that every
/// rule has a case. A rule nothing exercises refuses nothing.
fn runFixtureCases(allocator: std.mem.Allocator) !void {
    try validateReleaseScript(allocator, positive_fixture);
    for (negative_cases) |case| try expectNegativeCase(allocator, case);
    inline for (@typeInfo(ReleaseFailure).error_set.?) |member| {
        var covered = false;
        for (negative_cases) |case| {
            if (std.mem.eql(u8, @errorName(case.expected), member.name)) covered = true;
        }
        if (!covered) {
            std.debug.print("release workflow: rule {s} has no negative case\n", .{member.name});
            return error.UncoveredReleaseRule;
        }
    }
}

fn runReleaseWorkflow(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    try runFixtureCases(allocator);
    const source = try readFile(io, allocator, path);
    defer allocator.free(source);
    validateReleaseScript(allocator, source) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |refusal| {
            std.debug.print("{s}\n", .{releaseMessage(refusal)});
            return error.ReleaseWorkflowFailed;
        },
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
        try writeStdout(io, "release script: verify, container, advisory benchmark, target, and draft gates OK\n");
        return;
    }
    usage();
}

test "release script negative cases preserve each refusal and cover every rule" {
    try runFixtureCases(std.testing.allocator);
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

test "release script accepts the positive fixture" {
    try validateReleaseScript(std.testing.allocator, positive_fixture);
}

test "release script ignores a comment that names the Intel macOS target" {
    // The positive fixture already carries one; this adds a second, indented.
    try validateReleaseScript(std.testing.allocator, positive_fixture ++ "\n    # drop x86_64-macos-none\n");
}

test "release script joins a continued line before it applies a rule" {
    // The container rule needs `container run`, the arch, and the verifier on
    // one logical line. The positive fixture spreads them over three physical
    // lines, so it passes only if the continuation join works.
    try validateReleaseScript(std.testing.allocator, positive_fixture);
    const lines = try normalizeScript(std.testing.allocator, container_block);
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 1), lines.len);
}

test "release script comment inside a continuation ends the logical line" {
    const source = "bash scripts/verify.sh --release\n" ++
        "container run --arch amd64 \\\n" ++
        "# scripts/verify.sh --release\n";
    const lines = try normalizeScript(std.testing.allocator, source);
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expect(std.mem.find(u8, lines[1], "scripts/verify.sh") == null);
}

test "release script gate refuses the empty script" {
    try expectReleaseFailure(std.testing.allocator, "", error.MissingHostVerify);
}

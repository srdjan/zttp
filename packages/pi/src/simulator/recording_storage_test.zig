const std = @import("std");
const artifact = @import("artifact.zig");
const storage = @import("recording_storage.zig");
const IsolatedTmp = @import("../test_support/tmp.zig").IsolatedTmp;
const zts = @import("zts");

const testing = std.testing;

const Fixture = struct {
    tree: IsolatedTmp,
    case_root: [:0]u8,

    fn init() !Fixture {
        var tree = try IsolatedTmp.init(testing.allocator, "flow-promotion");
        errdefer tree.cleanup(testing.allocator);
        try tree.mkdir(testing.allocator, "case");
        const case_path = try tree.childPath(testing.allocator, "case");
        defer testing.allocator.free(case_path);
        var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
        defer io_backend.deinit();
        return .{
            .case_root = try std.Io.Dir.realPathFileAbsoluteAlloc(
                io_backend.io(),
                case_path,
                testing.allocator,
            ),
            .tree = tree,
        };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.case_root);
        self.tree.cleanup(testing.allocator);
    }

    fn read(self: *const Fixture, relative_path: []const u8) ![]u8 {
        const path = try std.fs.path.join(testing.allocator, &.{ self.case_root, relative_path });
        defer testing.allocator.free(path);
        return zts.file_io.readFile(testing.allocator, path, artifact.Limits.manifest_bytes);
    }

    fn pathExists(self: *const Fixture, relative_path: []const u8) !bool {
        const path = try std.fs.path.join(testing.allocator, &.{ self.case_root, relative_path });
        defer testing.allocator.free(path);
        var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
        defer io_backend.deinit();
        _ = std.Io.Dir.cwd().statFile(io_backend.io(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }
};

const Collected = struct {
    expected_bytes: []const u8,
    valid_trace: bool = true,
};

fn zeroDigest() artifact.Sha256Hex {
    return .{ .bytes = [_]u8{'0'} ** 64 };
}

fn collected(expected_bytes: []const u8) Collected {
    return .{ .expected_bytes = expected_bytes };
}

fn promoteCollected(fixture: *const Fixture, value: *const Collected) !artifact.Sha256Hex {
    return promoteCollectedWithFault(fixture, value, null);
}

fn promoteCollectedWithFault(
    fixture: *const Fixture,
    value: *const Collected,
    fault: ?storage.testing.PromotionFault,
) !artifact.Sha256Hex {
    const turns = [_]artifact.TurnExpectation{.{
        .index = 0,
        .user_input = "make the edit",
        .outcome = .approved,
        .final_response_sha256 = artifact.Sha256Hex.fromBytes("done"),
    }};
    const responses = [_]artifact.ResponseFixture{.{
        .index = 0,
        .turn_index = 0,
        .call_index = 0,
        .path = "responses/0.jsonl",
        .sha256 = zeroDigest(),
    }};
    const changes = [_]artifact.WorkspaceChange{.{ .path = "handler.ts", .kind = .changed }};
    const initial = [_]artifact.WorkspaceFixture{.{ .path = "handler.ts", .sha256 = zeroDigest() }};
    const expected = [_]artifact.WorkspaceFixture{.{ .path = "handler.ts", .sha256 = zeroDigest() }};
    const manifest = artifact.FlowManifest{
        .schema_version = artifact.schema_version,
        .flow_version = zeroDigest(),
        .case_name = "approved-edit",
        .evidence_class = .deterministic_harness,
        .executable = true,
        .provider = .anthropic,
        .model = "fixture-model",
        .turns = &turns,
        .model_responses = &responses,
        .approvals = &.{},
        .events = &.{},
        .allowed_workspace_changes = &changes,
        .initial_workspace = &initial,
        .turn_workspaces = &.{},
        .expected_workspace = &expected,
        .trace = .{ .path = "trace.json", .sha256 = zeroDigest() },
    };
    const model_calls = [_]artifact.ModelCheckpoint{.{
        .index = 0,
        .turn_index = 0,
        .call_index = 0,
        .transcript_prefix_count = 1,
        .transcript_sha256 = artifact.Sha256Hex.fromBytes("transcript"),
        .request_context_sha256 = artifact.Sha256Hex.fromBytes("context"),
        .transient_user_text_sha256 = null,
    }};
    const trace = artifact.InteractionTrace{
        .schema_version = artifact.schema_version,
        .model_calls = if (value.valid_trace) &model_calls else &.{},
        .approvals = &.{},
        .transcript_items = &.{},
        .apply_receipts = &.{},
    };
    const fixtures = [_]storage.FixtureBytes{
        .{ .role = .response, .path = "responses/0.jsonl", .bytes = "provider response bytes\n" },
        .{ .role = .initial_workspace, .path = "initial/handler.ts", .bytes = "export function handler() { return Response.text(\"old\"); }\n" },
        .{ .role = .expected_workspace, .path = "expected/handler.ts", .bytes = value.expected_bytes },
    };
    const input = storage.PromotionInput{
        .case_root_abs = fixture.case_root,
        .manifest = &manifest,
        .trace = &trace,
        .fixtures = &fixtures,
    };
    if (fault) |point| return storage.testing.promoteWithFault(testing.allocator, input, point);
    return storage.promote(testing.allocator, input);
}

fn expectActiveVersion(fixture: *const Fixture, expected: artifact.Sha256Hex) !void {
    var loaded = artifact.loadCase(testing.allocator, fixture.case_root);
    defer loaded.deinit();
    switch (loaded) {
        .available => |flow_case| try testing.expect(flow_case.flow_version.eql(expected)),
        .failure => return error.ExpectedActiveGeneration,
    }
}

test "recording storage promotes an initial validated generation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const value = collected("export function handler() { return Response.text(\"new\"); }\n");

    const flow_version = try promoteCollected(&fixture, &value);

    var loaded = artifact.loadCase(testing.allocator, fixture.case_root);
    defer loaded.deinit();
    switch (loaded) {
        .available => |flow_case| try testing.expect(flow_case.flow_version.eql(flow_version)),
        .failure => return error.ExpectedPromotedCase,
    }
}

test "recording storage revalidates replacement and removes the superseded generation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const first = collected("export function handler() { return Response.text(\"first\"); }\n");
    const first_version = try promoteCollected(&fixture, &first);
    const pointer_before = try fixture.read("case.json");
    defer testing.allocator.free(pointer_before);

    const second = collected("export function handler() { return Response.text(\"second\"); }\n");
    const second_version = try promoteCollected(&fixture, &second);
    const pointer_after = try fixture.read("case.json");
    defer testing.allocator.free(pointer_after);

    try testing.expect(!first_version.eql(second_version));
    try testing.expect(!std.mem.eql(u8, pointer_before, pointer_after));
    const old_manifest_path = try std.fmt.allocPrint(
        testing.allocator,
        "generations/{s}/manifest.json",
        .{first_version.slice()},
    );
    defer testing.allocator.free(old_manifest_path);
    try testing.expect(!try fixture.pathExists(old_manifest_path));

    var loaded = artifact.loadCase(testing.allocator, fixture.case_root);
    defer loaded.deinit();
    switch (loaded) {
        .available => |flow_case| try testing.expect(flow_case.flow_version.eql(second_version)),
        .failure => return error.ExpectedReplacementCase,
    }
}

test "recording storage treats promotion of the active flow as idempotent" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const value = collected("export function handler() { return Response.text(\"same\"); }\n");
    const first_version = try promoteCollected(&fixture, &value);
    const pointer_before = try fixture.read("case.json");
    defer testing.allocator.free(pointer_before);

    const second_version = try promoteCollected(&fixture, &value);
    const pointer_after = try fixture.read("case.json");
    defer testing.allocator.free(pointer_after);

    try testing.expect(first_version.eql(second_version));
    try testing.expectEqualStrings(pointer_before, pointer_after);
    try testing.expect(!try fixture.pathExists(".promotion-staging"));
    try testing.expect(!try fixture.pathExists(".case.json.tmp"));
}

test "pre-swap promotion faults preserve the complete active generation" {
    const faults = [_]storage.testing.PromotionFault{
        .stage_write,
        .stage_sync,
        .generation_rename,
        .generation_sync,
        .pointer_write,
        .pointer_rename,
    };

    for (faults) |fault| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const first = collected("export function handler() { return Response.text(\"first\"); }\n");
        const first_version = try promoteCollected(&fixture, &first);
        const pointer_before = try fixture.read("case.json");
        defer testing.allocator.free(pointer_before);

        const replacement = collected("export function handler() { return Response.text(\"second\"); }\n");
        try testing.expectError(
            error.InjectedPromotionFault,
            promoteCollectedWithFault(&fixture, &replacement, fault),
        );

        const pointer_after = try fixture.read("case.json");
        defer testing.allocator.free(pointer_after);
        try testing.expectEqualStrings(pointer_before, pointer_after);
        try expectActiveVersion(&fixture, first_version);
    }
}

test "post-swap promotion faults report activation and expose only the validated replacement" {
    const first = collected("export function handler() { return Response.text(\"first\"); }\n");
    const replacement = collected("export function handler() { return Response.text(\"second\"); }\n");

    var baseline = try Fixture.init();
    defer baseline.deinit();
    _ = try promoteCollected(&baseline, &first);
    const replacement_version = try promoteCollected(&baseline, &replacement);

    const faults = [_]storage.testing.PromotionFault{
        .pointer_sync,
        .active_revalidate,
        .superseded_cleanup,
        .staging_cleanup,
    };
    for (faults) |fault| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const first_version = try promoteCollected(&fixture, &first);

        try testing.expectError(
            error.ActivatedRecoveryRequired,
            promoteCollectedWithFault(&fixture, &replacement, fault),
        );

        try expectActiveVersion(&fixture, replacement_version);
        const old_manifest_path = try std.fmt.allocPrint(
            testing.allocator,
            "generations/{s}/manifest.json",
            .{first_version.slice()},
        );
        defer testing.allocator.free(old_manifest_path);
        const old_generation_expected = fault != .staging_cleanup;
        try testing.expectEqual(old_generation_expected, try fixture.pathExists(old_manifest_path));
        try testing.expect(try fixture.pathExists(".promotion-staging"));
    }
}

test "stale pointer temp blocks replacement and preserves the active pointer" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const first = collected("export function handler() { return Response.text(\"first\"); }\n");
    _ = try promoteCollected(&fixture, &first);
    const before = try fixture.read("case.json");
    defer testing.allocator.free(before);
    try fixture.tree.writeFile(testing.allocator, "case/.case.json.tmp", "stale promotion state\n");

    const replacement = collected("export function handler() { return Response.text(\"second\"); }\n");
    try testing.expectError(error.RecoveryRequired, promoteCollected(&fixture, &replacement));

    const after = try fixture.read("case.json");
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    var loaded = artifact.loadCase(testing.allocator, fixture.case_root);
    defer loaded.deinit();
    try testing.expect(std.meta.activeTag(loaded) == .available);
}

test "stale staging directory requires explicit recovery" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const first = collected("export function handler() { return Response.text(\"first\"); }\n");
    _ = try promoteCollected(&fixture, &first);
    const before = try fixture.read("case.json");
    defer testing.allocator.free(before);
    try fixture.tree.mkdir(testing.allocator, "case/.promotion-staging");

    const replacement = collected("export function handler() { return Response.text(\"second\"); }\n");
    try testing.expectError(error.RecoveryRequired, promoteCollected(&fixture, &replacement));

    const after = try fixture.read("case.json");
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "staged validation failure does not swap the active pointer" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const first = collected("export function handler() { return Response.text(\"first\"); }\n");
    _ = try promoteCollected(&fixture, &first);
    const before = try fixture.read("case.json");
    defer testing.allocator.free(before);

    var invalid = collected("export function handler() { return Response.text(\"invalid\"); }\n");
    invalid.valid_trace = false;
    try testing.expectError(error.InvalidArtifact, promoteCollected(&fixture, &invalid));

    const after = try fixture.read("case.json");
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    var loaded = artifact.loadCase(testing.allocator, fixture.case_root);
    defer loaded.deinit();
    try testing.expect(std.meta.activeTag(loaded) == .available);
}

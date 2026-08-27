//! Validate the exported proof-passport schema and its checksummed event log.
//! Repository smoke tooling only; this is not an installed command.

const std = @import("std");
const zts = @import("zts");
const session_events = @import("session/events.zig");

fn isLowerHexDigest(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn requiredString(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = object.get(field) orelse return error.MissingPassportField;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidPassportField,
    };
}

fn validatePassportBytes(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidPassport,
    };
    const schema = object.get("schemaVersion") orelse return error.MissingPassportField;
    if (schema != .integer or schema.integer != 1) return error.UnsupportedPassportSchema;
    if (!std.mem.eql(u8, try requiredString(object, "kind"), "zttp-proof-passport")) {
        return error.InvalidPassportKind;
    }
    if (!std.mem.eql(u8, try requiredString(object, "step"), "deployed")) {
        return error.PassportNotDeployed;
    }
    if (!isLowerHexDigest(try requiredString(object, "contractHash")) or
        !isLowerHexDigest(try requiredString(object, "policyHash")))
    {
        return error.InvalidPassportDigest;
    }
}

pub fn validatePassportFile(allocator: std.mem.Allocator, path: []const u8) !void {
    const bytes = try zts.file_io.readFile(allocator, path, 8 * 1024 * 1024);
    defer allocator.free(bytes);
    try validatePassportBytes(allocator, bytes);
}

pub fn validateEventsFile(allocator: std.mem.Allocator, path: []const u8) !void {
    var reader = try session_events.Reader.open(allocator, path);
    defer reader.deinit();
    var saw_verified_change_set = false;
    while (try reader.next()) |payload| {
        defer allocator.free(payload);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidEventEnvelope,
        };
        const version = object.get("v") orelse return error.InvalidEventEnvelope;
        const entry_id = object.get("entry_id") orelse return error.InvalidEventEnvelope;
        const kind = object.get("k") orelse return error.InvalidEventEnvelope;
        if (version != .integer or version.integer != session_events.schema_version or
            entry_id != .integer or kind != .string)
        {
            return error.InvalidEventEnvelope;
        }
        if (!std.mem.eql(u8, kind.string, "verified_change_set")) continue;
        const data = object.get("d") orelse return error.InvalidVerifiedChangeSet;
        if (data != .object) return error.InvalidVerifiedChangeSet;
        const ui_payload = data.object.get("ui_payload") orelse return error.InvalidVerifiedChangeSet;
        if (ui_payload != .object) return error.InvalidVerifiedChangeSet;
        const payload_kind = ui_payload.object.get("kind") orelse return error.InvalidVerifiedChangeSet;
        if (payload_kind != .string or
            !std.mem.eql(u8, payload_kind.string, "verified_change_set"))
        {
            return error.InvalidVerifiedChangeSet;
        }
        saw_verified_change_set = true;
    }
    if (!saw_verified_change_set) return error.MissingVerifiedChangeSet;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var args = std.process.Args.Iterator.init(init.args);
    defer args.deinit();
    _ = args.next();
    const passport_path = args.next() orelse return error.MissingPassportPath;
    const events_path = args.next() orelse return error.MissingEventsPath;
    if (args.next() != null) return error.UnexpectedArgument;

    validatePassportFile(allocator, passport_path) catch |err| {
        std.debug.print("demo passport check: passport invalid: {s}\n", .{@errorName(err)});
        return err;
    };
    validateEventsFile(allocator, events_path) catch |err| {
        std.debug.print("demo passport check: event journal invalid: {s}\n", .{@errorName(err)});
        return err;
    };
}

test "passport validator requires deployed schema and digests" {
    const valid =
        "{\"schemaVersion\":1,\"kind\":\"zttp-proof-passport\",\"step\":\"deployed\"," ++
        "\"contractHash\":\"" ++ "a" ** 64 ++ "\",\"policyHash\":\"" ++ "b" ** 64 ++ "\"}";
    try validatePassportBytes(std.testing.allocator, valid);
    try std.testing.expectError(
        error.PassportNotDeployed,
        validatePassportBytes(
            std.testing.allocator,
            "{\"schemaVersion\":1,\"kind\":\"zttp-proof-passport\",\"step\":\"draft\"," ++
                "\"contractHash\":\"" ++ "a" ** 64 ++ "\",\"policyHash\":\"" ++ "b" ** 64 ++ "\"}",
        ),
    );
}

test "event validator rejects a journal without a verified change set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "events.jsonl", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "events.jsonl", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectError(
        error.MissingVerifiedChangeSet,
        validateEventsFile(std.testing.allocator, path),
    );
}

//! Agent protocol request context: the root source reader, captured files, and repair bindings.

const std = @import("std");
const zts = @import("zts");
const agent_identity = @import("agent_identity.zig");
const module_graph_record = @import("module_graph_record.zig");
const envelope_mod = @import("agent_protocol_envelope.zig");
const Operation = envelope_mod.Operation;
const Identity = envelope_mod.Identity;

pub const RootSourceReader = struct {
    context: ?*anyopaque,
    readFn: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        max_bytes: usize,
    ) anyerror![]u8,

    fn read(
        reader: RootSourceReader,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        max_bytes: usize,
    ) anyerror![]u8 {
        return reader.readFn(reader.context, allocator, io, path, max_bytes);
    }
};

pub fn readRootSource(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: std.Io,
    path: []const u8,
    max_bytes: usize,
) anyerror![]u8 {
    return zts.file_io.readFile(allocator, path, max_bytes);
}

pub const CapturedFile = struct {
    relative_path: []const u8,
    absolute_path: []const u8,
    disk_source: []const u8,
    /// Borrows `disk_source` or the parsed request's string storage.
    effective_source: []const u8,
    source_digest: [64]u8,
    graph: module_graph_record.GraphRecord,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        reader: RootSourceReader,
        canonical_root: []const u8,
        requested_path: []const u8,
        operation: Operation,
        input: std.json.Value,
    ) module_graph_record.BuildError!CapturedFile {
        const relative_path = try agent_identity.canonicalRelPath(
            allocator,
            io,
            canonical_root,
            requested_path,
        );
        errdefer allocator.free(relative_path);

        const absolute_path = try std.fs.path.resolve(allocator, &.{ canonical_root, relative_path });
        errdefer allocator.free(absolute_path);

        const disk_source = reader.read(
            allocator,
            io,
            absolute_path,
            module_graph_record.max_source_bytes,
        ) catch return error.EntryUnreadable;
        errdefer allocator.free(disk_source);

        const effective_source = verifyContentOverride(operation, input) orelse disk_source;
        var graph = try module_graph_record.buildWithEntrySource(
            allocator,
            io,
            canonical_root,
            relative_path,
            effective_source,
        );
        errdefer graph.deinit(allocator);

        return .{
            .relative_path = relative_path,
            .absolute_path = absolute_path,
            .disk_source = disk_source,
            .effective_source = effective_source,
            .source_digest = agent_identity.sourceDigest(effective_source),
            .graph = graph,
        };
    }

    pub fn deinit(file: *CapturedFile, allocator: std.mem.Allocator) void {
        file.graph.deinit(allocator);
        allocator.free(file.disk_source);
        allocator.free(file.absolute_path);
        allocator.free(file.relative_path);
        file.* = undefined;
    }
};

fn verifyContentOverride(operation: Operation, input: std.json.Value) ?[]const u8 {
    if (operation != .verify) return null;
    const object = switch (input) {
        .object => |value| value,
        else => return null,
    };
    const content = object.get("content") orelse return null;
    return switch (content) {
        .string => |value| value,
        else => null,
    };
}

pub const RepairBinding = struct {
    source_digest: [64]u8,
    profile_id: []const u8,
    policy_hash: [64]u8,
    module_graph_hash: [64]u8,
    semantics_hash: [64]u8,

    pub fn current(source_digest: [64]u8, identity: Identity) RepairBinding {
        return .{
            .source_digest = source_digest,
            .profile_id = agent_identity.profile_id,
            .policy_hash = identity.policy_hash,
            .module_graph_hash = identity.module_graph_hash,
            .semantics_hash = zts.semanticsHash(),
        };
    }

    pub fn writeJson(self: RepairBinding, json: *std.json.Stringify) !void {
        try json.beginObject();
        try json.objectField("source_digest");
        try json.write(&self.source_digest);
        try json.objectField("profile_id");
        try json.write(self.profile_id);
        try json.objectField("policy_hash");
        try json.write(&self.policy_hash);
        try json.objectField("module_graph_hash");
        try json.write(&self.module_graph_hash);
        try json.objectField("semantics_hash");
        try json.write(&self.semantics_hash);
        try json.endObject();
    }
};

const RepairBindingCheck = union(enum) {
    valid,
    malformed: []const u8,
    stale: []const u8,
};

pub fn checkRepairBinding(value: ?std.json.Value, expected: RepairBinding) RepairBindingCheck {
    const object = switch (value orelse return .{ .malformed = "a repair must carry its `bound` identity object" }) {
        .object => |o| o,
        else => return .{ .malformed = "repair `bound` must be an object" },
    };
    if (object.count() != 5) {
        return .{ .malformed = "repair `bound` must contain exactly source_digest, profile_id, policy_hash, module_graph_hash, and semantics_hash" };
    }

    const fields = [_]struct { name: []const u8, expected: []const u8 }{
        .{ .name = "source_digest", .expected = &expected.source_digest },
        .{ .name = "profile_id", .expected = expected.profile_id },
        .{ .name = "policy_hash", .expected = &expected.policy_hash },
        .{ .name = "module_graph_hash", .expected = &expected.module_graph_hash },
        .{ .name = "semantics_hash", .expected = &expected.semantics_hash },
    };
    for (fields) |field| {
        const supplied = object.get(field.name) orelse
            return .{ .malformed = "repair `bound` is missing a required identity field" };
        if (supplied != .string) {
            return .{ .malformed = "every repair `bound` identity field must be a string" };
        }
        if (!std.mem.eql(u8, supplied.string, field.expected)) {
            return .{ .stale = field.name };
        }
    }
    return .valid;
}

pub fn contextFreeIdentity() Identity {
    return .{
        .policy_hash = zts.policyHash(),
        .module_graph_hash = module_graph_record.contextFreeHash(),
    };
}

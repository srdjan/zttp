//! Shared test helpers and fixtures for the agent protocol tests.

const std = @import("std");
const zts = @import("zts");
const agent_identity = @import("agent_identity.zig");
const module_graph_record = @import("module_graph_record.zig");
const testing = std.testing;
const dispatch_mod = @import("agent_protocol_dispatch.zig");
const handleRequest = dispatch_mod.handleRequest;
const request_mod = @import("agent_protocol_request.zig");
const RootSourceReader = request_mod.RootSourceReader;
const handleRequestWithRootReader = dispatch_mod.handleRequestWithRootReader;
const RepairBinding = request_mod.RepairBinding;

pub fn respond(allocator: std.mem.Allocator, request: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try handleRequest(allocator, testing.io, request, &out.writer);
    return out.toOwnedSlice();
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

pub fn respondWithRootSourceReader(
    allocator: std.mem.Allocator,
    request: []const u8,
    reader: RootSourceReader,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try handleRequestWithRootReader(allocator, testing.io, request, &out.writer, reader);
    return out.toOwnedSlice();
}

pub const ChangingRootReader = struct {
    directory: std.Io.Dir,
    path: []const u8,
    replacement: []const u8,
    read_count: u32 = 0,

    fn read(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        max_bytes: usize,
    ) anyerror![]u8 {
        const reader: *ChangingRootReader = @ptrCast(@alignCast(context orelse return error.MissingContext));
        if (reader.read_count != 0) return error.UnexpectedRootRead;
        if (max_bytes != module_graph_record.max_source_bytes) return error.UnexpectedSizeLimit;
        reader.read_count += 1;

        const source = try zts.file_io.readFile(allocator, path, max_bytes);
        errdefer allocator.free(source);
        try reader.directory.writeFile(io, .{
            .sub_path = reader.path,
            .data = reader.replacement,
        });
        return source;
    }

    pub fn rootSourceReader(reader: *ChangingRootReader) RootSourceReader {
        return .{
            .context = reader,
            .readFn = read,
        };
    }
};

pub fn currentTestRepairBinding(
    allocator: std.mem.Allocator,
    canonical_root: []const u8,
    file: []const u8,
) !RepairBinding {
    const abs = try std.fs.path.resolve(allocator, &.{ canonical_root, file });
    defer allocator.free(abs);
    const source = try zts.file_io.readFile(allocator, abs, module_graph_record.max_source_bytes);
    defer allocator.free(source);
    var graph = try module_graph_record.build(allocator, testing.io, canonical_root, file);
    defer graph.deinit(allocator);
    return RepairBinding.current(agent_identity.sourceDigest(source), .{
        .policy_hash = zts.policyHash(),
        .module_graph_hash = graph.hash,
    });
}

pub const TestStaleBindingField = enum { none, source_digest, profile_id, policy_hash, module_graph_hash, semantics_hash };

pub fn testRepairJson(
    allocator: std.mem.Allocator,
    intent: []const u8,
    line: u32,
    original: []const u8,
    replacement: []const u8,
    binding: RepairBinding,
    stale_field: TestStaleBindingField,
) ![]u8 {
    const stale = "stale";
    return allocator.print(
        \\{{"intent":"{s}","diagnostic_code":"ZTS604","line":{d},"original":{f},"replacement":{f},"bound":{{"source_digest":"{s}","profile_id":"{s}","policy_hash":"{s}","module_graph_hash":"{s}","semantics_hash":"{s}"}}}}
    , .{
        intent,
        line,
        std.json.fmt(original, .{}),
        std.json.fmt(replacement, .{}),
        if (stale_field == .source_digest) stale else &binding.source_digest,
        if (stale_field == .profile_id) stale else binding.profile_id,
        if (stale_field == .policy_hash) stale else &binding.policy_hash,
        if (stale_field == .module_graph_hash) stale else &binding.module_graph_hash,
        if (stale_field == .semantics_hash) stale else &binding.semantics_hash,
    });
}

pub const let_handler =
    \\
    \\
    \\structural Guardrails<T> = Proof<T, "state_isolated">;
    \\
    \\export function handler(req: Request): Guardrails<Response> {
    \\    let name = "world";
    \\    return Response.json({ hello: name });
    \\}
    \\
;

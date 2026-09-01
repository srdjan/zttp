const std = @import("std");
const zts_cli = @import("zts_cli");
const zts = @import("zts");
const CheckedPolicy = @import("serve_policy_types.zig").CheckedPolicy;

const precompile = zts_cli.precompile;

pub fn validateConfiguredPolicy(
    allocator: std.mem.Allocator,
    handler_path: []const u8,
    sql_schema_path: ?[]const u8,
    system_path: ?[]const u8,
    policy_source: []const u8,
) !CheckedPolicy {
    var result = try precompile.runCheckOnlyWithOptions(allocator, handler_path, .{
        .sql_schema_path = sql_schema_path,
        .json_mode = true,
        .system_path = system_path,
        .policy_source = policy_source,
    });
    defer result.deinit(allocator);
    if (result.totalErrors() == 0) {
        var policy = try zts.handler_policy.parsePolicyJson(allocator, policy_source);
        errdefer policy.deinit(allocator);
        const contract = result.contract orelse return error.PolicyContextFailed;
        result.contract = null;
        return .{ .contract = contract, .policy = policy };
    }

    var card_buf: std.ArrayList(u8) = .empty;
    defer card_buf.deinit(allocator);
    var card_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &card_buf);
    precompile.formatProofCard(&card_writer.writer, &result, handler_path);
    card_buf = card_writer.toArrayList();
    if (card_buf.items.len > 0) {
        _ = std.c.write(std.c.STDERR_FILENO, card_buf.items.ptr, card_buf.items.len);
    }
    return if (result.policy_errors > 0)
        error.PolicyViolation
    else
        error.PolicyContextFailed;
}

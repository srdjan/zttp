//! Shared test helpers for the type syntax tests.

const std = @import("std");
const ir = @import("ir.zig");
const store_mod = @import("type_syntax_store.zig");
const NodeIndex = store_mod.NodeIndex;
const NodeTag = store_mod.NodeTag;
const Store = store_mod.Store;
const scan_mod = @import("type_syntax_scan.zig");
const Cursor = scan_mod.Cursor;
const parser_mod = @import("type_syntax_parser.zig");
const parseAndStore = parser_mod.parseAndStore;

pub const TestRuntime = struct {
    nodes: ir.IRStore,
    constants: ir.ConstantPool,

    pub fn init(allocator: std.mem.Allocator) TestRuntime {
        return .{
            .nodes = ir.IRStore.init(allocator),
            .constants = ir.ConstantPool.init(allocator),
        };
    }

    pub fn deinit(self: *TestRuntime) void {
        self.nodes.deinit();
        self.constants.deinit();
    }

    pub fn view(self: *const TestRuntime) ir.IrView {
        return ir.IrView.fromIRStore(&self.nodes, &self.constants);
    }

    pub fn addCall(self: *TestRuntime, offset: u32) !ir.NodeIndex {
        return self.nodes.add(.{
            .tag = .call,
            .loc = .{ .line = 1, .column = offset + 1, .offset = offset, .end_offset = offset + 1 },
            .data = .{ .call = .{
                .callee = ir.null_node,
                .args_start = ir.null_node,
                .args_count = 0,
            } },
        });
    }

    pub fn addFunction(self: *TestRuntime, tag: ir.NodeTag, offset: u32) !ir.NodeIndex {
        if (tag != .function_expr and tag != .arrow_function) return error.TestUnexpectedResult;
        return self.nodes.add(.{
            .tag = tag,
            .loc = .{ .line = 1, .column = offset + 1, .offset = offset, .end_offset = offset + 1 },
            .data = .{ .function = .{
                .scope_id = 0,
                .name_atom = 0,
                .params_start = ir.null_node,
                .params_count = 0,
                .body = ir.null_node,
                .flags = .{},
            } },
        });
    }
};

pub fn validateAfterAllocationFailure(store: *Store) !void {
    const allocator = store.allocator;
    store.allocator = std.testing.allocator;
    defer store.allocator = allocator;
    try store.validate();
}

/// Publish one `number` annotation so a test starts from prior syntax.
pub fn seedNumberAnnotation(store: *Store) !void {
    var cursor = Cursor.init(store.source);
    switch (try parseAndStore(store, .global(300), store.source, 0, &cursor)) {
        .parsed => {},
        .failure, .excluded => return error.TestUnexpectedResult,
    }
}

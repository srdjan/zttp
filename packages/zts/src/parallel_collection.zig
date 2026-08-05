//! Context-owned state for structured concurrent I/O collection.

const std = @import("std");

/// Descriptor for an outbound HTTP request collected during thunk execution.
pub const FetchDescriptor = struct {
    url: []const u8,
    method: std.http.Method,
    body: ?[]const u8,
    headers: std.ArrayList(std.http.Header),
    max_response_bytes: usize,

    pub fn deinit(self: *FetchDescriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.body) |body| allocator.free(body);
        self.headers.deinit(allocator);
    }
};

/// Borrowed collection target installed while `parallel` or `race` invokes
/// its thunks. The invoking operation owns both this value and its descriptor
/// storage.
pub const ParallelCollector = struct {
    descriptors: []FetchDescriptor,
    count: u32,
    allocator: std.mem.Allocator,
    capacity: u32,
};

/// Explicit per-Context collector stack. A scope borrows its collector and
/// restores the previous borrow when the operation returns or errors.
pub const State = struct {
    active: ?*ParallelCollector = null,

    pub fn enter(self: *State, collector: *ParallelCollector) Scope {
        const previous = self.active;
        self.active = collector;
        return .{
            .state = self,
            .collector = collector,
            .previous = previous,
        };
    }

    pub fn clear(self: *State) void {
        self.active = null;
    }
};

pub const Scope = struct {
    state: *State,
    collector: *ParallelCollector,
    previous: ?*ParallelCollector,

    pub fn restore(self: Scope) void {
        std.debug.assert(self.state.active == self.collector);
        self.state.active = self.previous;
    }
};

test "parallel collector scopes restore their nested parent" {
    var state: State = .{};
    var outer_descriptors: [1]FetchDescriptor = undefined;
    var inner_descriptors: [1]FetchDescriptor = undefined;
    var outer = ParallelCollector{
        .descriptors = &outer_descriptors,
        .count = 0,
        .allocator = std.testing.allocator,
        .capacity = 1,
    };
    var inner = ParallelCollector{
        .descriptors = &inner_descriptors,
        .count = 0,
        .allocator = std.testing.allocator,
        .capacity = 1,
    };

    const outer_scope = state.enter(&outer);
    try std.testing.expect(state.active == &outer);

    const inner_scope = state.enter(&inner);
    try std.testing.expect(state.active == &inner);

    inner_scope.restore();
    try std.testing.expect(state.active == &outer);

    outer_scope.restore();
    try std.testing.expect(state.active == null);
}

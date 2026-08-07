//! HandlerInstance-owned adapter for the zts engine surface used by the HTTP server.
//!
//! Keep direct `zts` and `handler_instance` imports here so server code depends on
//! handler execution capabilities instead of engine internals.

const std = @import("std");
const zq = @import("zts");
const handler_instance = @import("handler_instance.zig");
const http_types = @import("http_types.zig");

pub const HandlerInstance = handler_instance.HandlerInstance;
pub const HandlerPool = @import("runtime_pool.zig").HandlerPool;
pub const RuntimeConfig = @import("runtime_config.zig").RuntimeConfig;
pub const ResponseHandle = HandlerPool.ResponseHandle;
pub const HandlerContract = zq.HandlerContract;
pub const HandlerProperties = zq.handler_contract.HandlerProperties;
pub const RuntimePolicy = zq.RuntimePolicy;
pub const SqlQueryInfo = zq.handler_policy.SqlQueryInfo;
pub const normalizedSqlQuery = zq.handler_policy.normalizedSqlQuery;
pub const sqlQueryIsReadOnly = zq.handler_policy.sqlQueryIsReadOnly;
pub const JSValue = zq.JSValue;
pub const Instant = zq.compat.Instant;
pub const Timer = zq.compat.Timer;
pub const Mutex = zq.compat.Mutex;
pub const RwLock = zq.compat.RwLock;

pub fn readFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]const u8 {
    return zq.file_io.readFile(allocator, path, max_bytes);
}

pub fn initSecurityEvents(allocator: std.mem.Allocator, capacity: usize) !void {
    try zq.security_events.initGlobal(allocator, capacity);
}

pub fn deinitSecurityEvents() void {
    zq.security_events.deinitGlobal();
}

pub fn unixMillis() i64 {
    return zq.trace.unixMillis();
}

pub fn monotonicNowNs() !u64 {
    return zq.compat.monotonicNowNs();
}

pub fn jsInt(value: i32) JSValue {
    return JSValue.fromInt(value);
}

pub fn defaultHandlerProperties() HandlerProperties {
    return .{
        .pure = false,
        .read_only = false,
        .stateless = false,
        .retry_safe = false,
        .deterministic = false,
        .has_egress = false,
    };
}

pub fn contractRuntimePolicy(contract: *const HandlerContract) RuntimePolicy {
    return zq.handler_policy.contractToRuntimePolicy(contract);
}

pub fn initHandlerPool(
    allocator: std.mem.Allocator,
    config: RuntimeConfig,
    handler_code: []const u8,
    handler_filename: []const u8,
    pool_size: usize,
    pool_wait_timeout_ms: u32,
    embedded_bytecode: ?[]const u8,
    runtime_dep_bytecodes: ?[]const []const u8,
) !HandlerPool {
    return HandlerPool.initWithEmbeddedAndDeps(
        allocator,
        config,
        handler_code,
        handler_filename,
        pool_size,
        pool_wait_timeout_ms,
        embedded_bytecode,
        runtime_dep_bytecodes,
    );
}

pub fn executeHandlerBorrowed(pool: *HandlerPool, request: http_types.HttpRequestView) !ResponseHandle {
    return pool.executeHandlerBorrowed(request);
}

/// Resolved source location of a handler fault. Re-exported so `server.zig`
/// can name it without importing the engine directly - it reaches the engine
/// only through this adapter, and the purity script enforces that.
pub const FaultLocation = zq.bytecode.LineEntry;

/// Execute, and on a type fault write the runtime's resolved source line into
/// `fault_out`. The server's 500 site needs `line:column` after the runtime is
/// released, so the pool copies it out while the runtime is still in hand.
pub fn executeHandlerBorrowedCapturingFault(
    pool: *HandlerPool,
    request: http_types.HttpRequestView,
    fault_out: *?FaultLocation,
) !ResponseHandle {
    return pool.executeHandlerBorrowedCapturingFault(request, fault_out);
}

test "a type fault leaves its source line on the runtime for the pool to copy out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try handler_instance.HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    // Fresh runtime: nothing to report.
    try std.testing.expect(rt.last_fault_location == null);

    // A handler that calls a non-function faults with HandlerTypeFault, and the
    // runtime resolves the source line from the bytecode line table.
    try rt.loadHandler(
        \\function handler(req) {
        \\  const missing = undefined;
        \\  return missing();
        \\}
    , "<type-fault>");

    var request = http_types.HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    try std.testing.expectError(error.HandlerTypeFault, rt.executeHandler(request.asView()));
    const loc = rt.last_fault_location orelse return error.ExpectedFaultLocation;
    try std.testing.expect(loc.line > 0);
}

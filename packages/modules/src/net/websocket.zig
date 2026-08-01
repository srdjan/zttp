//! zttp:websocket - bidirectional connections with hibernation.
//!
//! Six exports. All dispatch through runtime-owned callbacks installed
//! by the zts-side shim. Until installed, each call throws the same
//! "runtime not installed" error.

const std = @import("std");
const sdk = @import("zttp-sdk");

pub const MODULE_STATE_SLOT: usize = 12; // module_slots.Slot.websocket

pub const WsCallFn = *const fn (
    runtime_ptr: *anyopaque,
    handle: *sdk.ModuleHandle,
    args: []const sdk.JSValue,
) anyerror!sdk.JSValue;

pub const WebSocketCallbacks = struct {
    runtime_ptr: *anyopaque,
    send_fn: WsCallFn,
    close_fn: WsCallFn,
    serialize_attachment_fn: WsCallFn,
    deserialize_attachment_fn: WsCallFn,
    get_web_sockets_fn: WsCallFn,
    set_auto_response_fn: WsCallFn,
};

pub const binding = sdk.ModuleBinding{
    .specifier = "zttp:websocket",
    .name = "websocket",
    // .network: send/close write to the peer socket via the runtime callback.
    // .filesystem: attachment serialization may persist hibernation state.
    .required_capabilities = &.{ .clock, .runtime_callback, .network, .filesystem, .policy_check, .websocket },
    .stateful = true,
    .exports = &.{
        // pool.sendFrame -> writeServerFrame(fd): a socket write.
        .{ .name = "send", .required_capabilities = &.{ .runtime_callback, .network }, .module_func = sendImpl, .arg_count = 2, .effect = .write, .returns = .undefined, .param_types = &.{ .object, .string } },
        // pool.sendFrameAndShutdown -> writeServerFrame(fd) + shutdown(fd).
        .{ .name = "close", .required_capabilities = &.{ .runtime_callback, .network }, .module_func = closeImpl, .arg_count = 3, .required_arg_count = 1, .effect = .write, .returns = .undefined, .param_types = &.{ .object, .number, .string } },
        // pool.setAttachment writes an attachment file when the pool has an
        // attachments dir configured; otherwise it is memory only. Declares
        // filesystem because the disk path is reachable.
        .{ .name = "serializeAttachment", .required_capabilities = &.{ .runtime_callback, .filesystem }, .module_func = serializeAttachmentImpl, .arg_count = 2, .effect = .write, .returns = .undefined, .param_types = &.{ .object, .string } },
        // pool.copyAttachment reads the in-memory attachment; the disk read
        // helper belongs to the hibernation resume path, not this export.
        .{ .name = "deserializeAttachment", .required_capabilities = &.{.runtime_callback}, .module_func = deserializeAttachmentImpl, .arg_count = 1, .effect = .read, .returns = .optional_string, .param_types = &.{.object} },
        // pool.snapshotRoom: a locked map lookup and a slice copy.
        .{ .name = "getWebSockets", .required_capabilities = &.{.runtime_callback}, .module_func = getWebSocketsImpl, .arg_count = 1, .effect = .read, .returns = .object, .param_types = &.{.string} },
        // pool.setAutoResponse stores two owned slices on the connection.
        .{ .name = "setAutoResponse", .required_capabilities = &.{.runtime_callback}, .module_func = setAutoResponseImpl, .arg_count = 3, .effect = .write, .returns = .undefined, .param_types = &.{ .object, .string, .string } },
    },
};

test "public binding matches the executable WebSocket callback contract" {
    try std.testing.expectEqual(@as(usize, 6), binding.exports.len);
    for (binding.exports) |exp| {
        try std.testing.expect(!std.mem.eql(u8, exp.name, "roomFromPath"));
        if (std.mem.eql(u8, exp.name, "setAutoResponse")) {
            try std.testing.expectEqual(@as(u8, 3), exp.arg_count);
            try std.testing.expectEqual(@as(usize, 3), exp.param_types.len);
            try std.testing.expectEqual(sdk.ReturnKind.object, exp.param_types[0]);
            try std.testing.expectEqual(sdk.ReturnKind.string, exp.param_types[1]);
            try std.testing.expectEqual(sdk.ReturnKind.string, exp.param_types[2]);
        }
    }
}

fn dispatch(handle: *sdk.ModuleHandle, args: []const sdk.JSValue, comptime field: []const u8) anyerror!sdk.JSValue {
    const state = sdk.getModuleState(handle, WebSocketCallbacks, MODULE_STATE_SLOT) orelse {
        return sdk.throwError(handle, "Error", "zttp:websocket runtime not installed");
    };
    try sdk.requireCapability(handle, .runtime_callback);
    return @field(state, field)(state.runtime_ptr, handle, args);
}

fn sendImpl(h: *sdk.ModuleHandle, _: sdk.JSValue, a: []const sdk.JSValue) anyerror!sdk.JSValue {
    return dispatch(h, a, "send_fn");
}
fn closeImpl(h: *sdk.ModuleHandle, _: sdk.JSValue, a: []const sdk.JSValue) anyerror!sdk.JSValue {
    return dispatch(h, a, "close_fn");
}
fn serializeAttachmentImpl(h: *sdk.ModuleHandle, _: sdk.JSValue, a: []const sdk.JSValue) anyerror!sdk.JSValue {
    return dispatch(h, a, "serialize_attachment_fn");
}
fn deserializeAttachmentImpl(h: *sdk.ModuleHandle, _: sdk.JSValue, a: []const sdk.JSValue) anyerror!sdk.JSValue {
    return dispatch(h, a, "deserialize_attachment_fn");
}
fn getWebSocketsImpl(h: *sdk.ModuleHandle, _: sdk.JSValue, a: []const sdk.JSValue) anyerror!sdk.JSValue {
    return dispatch(h, a, "get_web_sockets_fn");
}
fn setAutoResponseImpl(h: *sdk.ModuleHandle, _: sdk.JSValue, a: []const sdk.JSValue) anyerror!sdk.JSValue {
    return dispatch(h, a, "set_auto_response_fn");
}

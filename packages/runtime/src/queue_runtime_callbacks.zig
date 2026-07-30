//! Actor-queue runtime callbacks: the native implementations behind the
//! `zttp:queue` module exports (send / request / receive / ack / nack /
//! reply).
//!
//! Extracted from handler_instance.zig to keep the request-lifecycle struct
//! focused, mirroring ws_runtime_callbacks.zig. Each callback receives the
//! owning HandlerInstance as an opaque pointer and dispatches against its
//! process-local mailbox (`HandlerInstance.queue_system_ref`); the table is
//! registered by `HandlerInstance.installQueueModuleState`.

const std = @import("std");
const zq = @import("zts");
const actor_queue = @import("actor_queue.zig");
const handler_instance = @import("handler_instance.zig");

const HandlerInstance = handler_instance.HandlerInstance;

fn queueRef(self: *HandlerInstance) ?*actor_queue.ActorQueue {
    return self.queue_system_ref;
}

/// Per-pooled-instance reply identity for `zttp:queue.request()`/
/// `receive()` round trips. `config.queue_actor_name` ("main" by default)
/// is a single value shared by every pooled HandlerInstance, so using it directly
/// as the reply-to actor would let concurrent in-flight requests on
/// different pool slots cross-deliver each other's replies out of the
/// same shared mailbox. Suffixing with this instance's stable address
/// (each pool slot's HandlerInstance is allocated once and reused, never moved)
/// gives every concurrently in-flight request its own private mailbox
/// while leaving explicit, well-known actor names (e.g. `receive("worker")`)
/// untouched.
fn queueSelfActorName(self: *HandlerInstance, buf: *[128]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}#{x}", .{ self.config.queue_actor_name, @intFromPtr(self) }) catch self.config.queue_actor_name;
}

pub fn queueSendCallback(runtime_ptr: *anyopaque, ctx: *zq.Context, target: []const u8, payload: zq.JSValue) anyerror!zq.JSValue {
    const rt: *HandlerInstance = @ptrCast(@alignCast(runtime_ptr));
    return queueSendInternal(rt, ctx, target, payload, false);
}

pub fn queueRequestCallback(runtime_ptr: *anyopaque, ctx: *zq.Context, target: []const u8, payload: zq.JSValue) anyerror!zq.JSValue {
    const rt: *HandlerInstance = @ptrCast(@alignCast(runtime_ptr));
    return queueSendInternal(rt, ctx, target, payload, true);
}

pub fn queueReceiveCallback(runtime_ptr: *anyopaque, ctx: *zq.Context, actor: ?[]const u8) anyerror!zq.JSValue {
    const rt: *HandlerInstance = @ptrCast(@alignCast(runtime_ptr));
    const queue = queueRef(rt) orelse return zq.modules.util.createPlainResultErr(ctx, "queue runtime is not installed");
    var actor_buf: [128]u8 = undefined;
    const actor_name = actor orelse queueSelfActorName(rt, &actor_buf);
    const message = queue.receive(actor_name) catch |err| {
        return queueErrorResult(ctx, err);
    };
    const msg = message orelse return zq.modules.util.createPlainResultOk(ctx, zq.JSValue.null_val);
    return zq.modules.util.createPlainResultOk(ctx, try queueMessageToValue(rt, ctx, msg));
}

pub fn queueAckCallback(runtime_ptr: *anyopaque, ctx: *zq.Context, id_text: []const u8) anyerror!zq.JSValue {
    const rt: *HandlerInstance = @ptrCast(@alignCast(runtime_ptr));
    const queue = queueRef(rt) orelse return zq.modules.util.createPlainResultErr(ctx, "queue runtime is not installed");
    const id = parseMessageId(id_text) catch return zq.modules.util.createPlainResultErr(ctx, "invalid message id");
    if (!queue.ack(id)) return zq.modules.util.createPlainResultErr(ctx, "message is not in flight");
    return zq.modules.util.createPlainResultOk(ctx, zq.JSValue.true_val);
}

pub fn queueNackCallback(runtime_ptr: *anyopaque, ctx: *zq.Context, id_text: []const u8, reason: []const u8) anyerror!zq.JSValue {
    const rt: *HandlerInstance = @ptrCast(@alignCast(runtime_ptr));
    const queue = queueRef(rt) orelse return zq.modules.util.createPlainResultErr(ctx, "queue runtime is not installed");
    const id = parseMessageId(id_text) catch return zq.modules.util.createPlainResultErr(ctx, "invalid message id");
    const outcome = queue.nack(id, reason) catch |err| {
        return queueErrorResult(ctx, err);
    };
    return switch (outcome) {
        .not_found => zq.modules.util.createPlainResultErr(ctx, "message is not in flight"),
        .requeued => zq.modules.util.createPlainResultOk(ctx, try ctx.createString("requeued")),
        .dead_lettered => zq.modules.util.createPlainResultOk(ctx, try ctx.createString("dead_lettered")),
    };
}

pub fn queueReplyCallback(runtime_ptr: *anyopaque, ctx: *zq.Context, id_text: []const u8, payload: zq.JSValue) anyerror!zq.JSValue {
    const rt: *HandlerInstance = @ptrCast(@alignCast(runtime_ptr));
    const queue = queueRef(rt) orelse return zq.modules.util.createPlainResultErr(ctx, "queue runtime is not installed");
    const id = parseMessageId(id_text) catch return zq.modules.util.createPlainResultErr(ctx, "invalid message id");
    const payload_json = zq.http.valueToJson(ctx, payload) catch |err| {
        return queueErrorResult(ctx, err);
    };
    defer ctx.allocator.free(payload_json);
    const reply_id = queue.reply(id, payload_json, rt.config.queue_max_attempts) catch |err| {
        return queueErrorResult(ctx, err);
    };
    return queueIdResult(ctx, reply_id);
}

/// pub for the queue tests in zruntime_tests.zig, which drive send/request
/// without a JS handler in the loop.
pub fn queueSendInternal(self: *HandlerInstance, ctx: *zq.Context, target: []const u8, payload: zq.JSValue, comptime request_reply: bool) !zq.JSValue {
    const queue = queueRef(self) orelse return zq.modules.util.createPlainResultErr(ctx, "queue runtime is not installed");
    const payload_json = zq.http.valueToJson(ctx, payload) catch |err| {
        return queueErrorResult(ctx, err);
    };
    defer ctx.allocator.free(payload_json);
    var actor_buf: [128]u8 = undefined;
    const source = queueSelfActorName(self, &actor_buf);
    const id = queue.send(target, payload_json, .{
        .source = source,
        .reply_to = if (request_reply) source else null,
        .max_attempts = self.config.queue_max_attempts,
    }) catch |err| {
        return queueErrorResult(ctx, err);
    };
    return queueIdResult(ctx, id);
}

fn queueMessageToValue(self: *HandlerInstance, ctx: *zq.Context, msg: *const actor_queue.MessageEnvelope) !zq.JSValue {
    _ = self;
    const obj = try ctx.createObject(ctx.object_prototype);
    try setStringField(ctx, obj, "id", try formatMessageId(ctx, msg.id));
    try setStringField(ctx, obj, "source", try ctx.createString(msg.source));
    try setStringField(ctx, obj, "target", try ctx.createString(msg.target));
    const attempt_limit: u32 = @intCast(std.math.maxInt(i32));
    const attempt_i32: i32 = @intCast(@min(msg.attempt, attempt_limit));
    try ctx.setPropertyChecked(obj, try ctx.atoms.intern("attempt"), zq.JSValue.fromInt(attempt_i32));
    try ctx.setPropertyChecked(obj, try ctx.atoms.intern("payload"), zq.trace.jsonToJSValue(ctx, msg.payload_json));
    if (msg.correlation_id) |correlation_id| {
        try setStringField(ctx, obj, "correlationId", try formatMessageId(ctx, correlation_id));
    }
    if (msg.reply_to) |reply_to| {
        try setStringField(ctx, obj, "replyTo", try ctx.createString(reply_to));
    }
    return obj.toValue();
}

fn queueIdResult(ctx: *zq.Context, id: actor_queue.MessageId) !zq.JSValue {
    return zq.modules.util.createPlainResultOk(ctx, try formatMessageId(ctx, id));
}

fn formatMessageId(ctx: *zq.Context, id: actor_queue.MessageId) !zq.JSValue {
    var buf: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable;
    return ctx.createString(text);
}

fn setStringField(ctx: *zq.Context, obj: *zq.JSObject, name: []const u8, val: zq.JSValue) !void {
    try ctx.setPropertyChecked(obj, try ctx.atoms.intern(name), val);
}

fn parseMessageId(id_text: []const u8) !actor_queue.MessageId {
    return std.fmt.parseInt(actor_queue.MessageId, id_text, 10);
}

fn queueErrorResult(ctx: *zq.Context, err: anyerror) !zq.JSValue {
    const message = switch (err) {
        error.QueueFull => "queue full",
        error.InvalidActor => "invalid actor",
        error.MessageNotInFlight => "message is not in flight",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
    return zq.modules.util.createPlainResultErr(ctx, message);
}

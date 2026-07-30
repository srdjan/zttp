//! Native JS-callable runtime builtins extracted from zruntime.zig.
//!
//! Each `*Native` function matches the engine's native-fn signature
//! (ctx_ptr, this, args) -> anyerror!zq.JSValue and is registered as a
//! method on a JS prototype during runtime setup. The helpers used here
//! (`beginBodyRead`, `getStringData`) live with the HTTP natives they
//! belong to.

const std = @import("std");
const zq = @import("zts");
const http = @import("runtime_http.zig");
const natives = @import("runtime_natives.zig");

pub fn bodyTextNative(ctx_ptr: *anyopaque, this: zq.JSValue, _: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    const body_val = http.beginBodyRead(ctx, this);
    if (ctx.hasException()) return zq.JSValue.exception_val;
    if (body_val.isNull() or body_val.isUndefined()) {
        return ctx.createString("");
    }
    if (body_val.isAnyString()) {
        return body_val;
    }
    return ctx.createString("");
}

pub fn bodyJsonNative(ctx_ptr: *anyopaque, this: zq.JSValue, _: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    const body_val = http.beginBodyRead(ctx, this);
    if (ctx.hasException()) return zq.JSValue.exception_val;
    if (body_val.isNull() or body_val.isUndefined()) {
        return zq.JSValue.undefined_val;
    }
    const body = natives.getStringData(body_val) orelse return zq.JSValue.undefined_val;
    return zq.builtins.parseJsonValue(ctx, body) catch zq.JSValue.undefined_val;
}
